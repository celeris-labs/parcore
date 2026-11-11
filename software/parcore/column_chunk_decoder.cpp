#include <libstf/profiling.hpp>
#include <parcore/column_chunk_decoder.hpp>

#include <stdexcept>

using libstf::Profiler;

namespace parcore {

ColumnChunkDecoder::ColumnChunkDecoder(
    std::shared_ptr<coyote::cThread> cthread,
    std::shared_ptr<libstf::TLBManager> tlb_manager,
    std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
    std::shared_ptr<ColumnChunkDecoderConfig> column_chunk_config,
    libstf::stream_t decoder)
    : cthread_(std::move(cthread)), tlb_manager_(std::move(tlb_manager)),
      output_buffer_manager_(std::move(output_buffer_manager)),
      column_chunk_config_(std::move(column_chunk_config)),
      decoder_(decoder), column_chunk_enqueued_configs_(0) {}

const libstf::stream_t &ColumnChunkDecoder::decoder() const { return decoder_; }

libstf::stream_t ColumnChunkDecoder::values_stream() const {
  return column_chunk_config_->has_string_decoders() ? 2 * decoder_ : decoder_;
}

libstf::stream_t ColumnChunkDecoder::heap_stream() const {
  if (!column_chunk_config_->has_string_decoders()) {
    throw std::logic_error("Decoders without strings have no heap stream");
  }
  return 2 * decoder_ + 1;
}

ColumnChunkDecoder::Handle::Handle(
    std::shared_ptr<ColumnChunkDecoder> column_chunk_decoder,
    std::unique_lock<std::mutex> lock,
    std::shared_ptr<libstf::OutputHandle> output_handle)
    : column_chunk_decoder_(std::move(column_chunk_decoder)),
      lock_(std::move(lock)), output_handle_(output_handle),
      chunk_written_(false) {}

void ColumnChunkDecoder::Handle::add_chunk(
    const std::shared_ptr<libstf::Buffer> &buffer) {
  assert(!chunk_written_);

  // Buffer here could be null to signal that data is provided to the hardware
  // through a side-channel (e.g. RDMA reader wired directly into the decoder).
  if (buffer != nullptr)
    column_chunk_decoder_->enqueue_stream_input(buffer);

  chunk_written_ = true;
}

std::shared_ptr<libstf::OutputHandle> ColumnChunkDecoder::Handle::done() && {
  if (!chunk_written_)
    throw std::runtime_error("chunk data has not been written when calling done()");

  // We return the data. The 'this' object (Handle) is destroyed
  // immediately after this call, which triggers the lock's destructor.
  return std::move(output_handle_);
}

const std::string prefix = "parcore::ColumnChunkDecoder";

// Keeps a Profiler region open while it is in scope, also when an exception leaves the scope
struct ProfilerRegion {
  explicit ProfilerRegion(std::string name) : name_(std::move(name)) {
    Profiler::open_regions({name_});
  }
  ~ProfilerRegion() { Profiler::close_regions({name_}); }
  ProfilerRegion(const ProfilerRegion &) = delete;
  ProfilerRegion &operator=(const ProfilerRegion &) = delete;

private:
  std::string name_;
};

std::unique_ptr<ColumnChunkDecoder::Handle>
ColumnChunkDecoder::decode_column_chunk(
    const metadata::ColumnChunk &column_chunk, bool defer_dict_decoding) {
  std::unique_lock lock(mtx);
  ProfilerRegion region(prefix + "decode_column_chunk");
  assert(column_chunk_enqueued_configs_ + 1 <
         column_chunk_config_->maximum_num_enqueued_configs());

  // The config is enqueued first, as it checks that the decoder supports the chunk before it
  // writes anything. The decoder does not produce output before its input is enqueued through the
  // returned Handle, so the output handle is acquired in time. The heap address is 0, so the
  // records hold offsets into the heap.
  column_chunk_config_->enqueue_column_chunk(
      decoder_, column_chunk.compression, column_chunk.num_values,
      metadata::to_libstf_type(column_chunk.type), column_chunk.is_required,
      column_chunk.logical_type(), defer_dict_decoding, 0);

  auto output_handle =
      output_buffer_manager_->acquire_output_handle(output_streams(column_chunk));

  column_chunk_enqueued_configs_ += 1;

  return std::make_unique<Handle>(shared_from_this(), std::move(lock),
                                  output_handle);
}

void ColumnChunkDecoder::finished_decoding_column_chunk(
    const metadata::ColumnChunk &column_chunk) {
  std::unique_lock lock(mtx);
  column_chunk_enqueued_configs_ -= 1;
}

libstf::stream_mask_t ColumnChunkDecoder::output_streams(
    const metadata::ColumnChunk &column_chunk) const {
  libstf::stream_mask_t mask;
  mask.set(values_stream());
  if (metadata::is_string_type(column_chunk.type))
    mask.set(heap_stream());
  return mask;
}

void ColumnChunkDecoder::enqueue_stream_input(
    const std::shared_ptr<libstf::Buffer> &buffer) {
  Profiler::open_regions({prefix + "enqueue_stream_input"});
  auto byte_ptr = static_cast<const std::byte *>(buffer->ptr);
  tlb_manager_->ensure_tlb_mapping(buffer->ptr, buffer->capacity);

  for (size_t off = 0; off < buffer->size; off += coyote::MAX_TRANSFER_SIZE) {
    // Get the address and output_size of this chunk
    auto curr_ptr = (void *)(byte_ptr + off);
    auto input_size = std::min(buffer->size - off, coyote::MAX_TRANSFER_SIZE);

    // Configure the data transfer
    coyote::localSg sg;
    // NOTE: This is a current limitation of coyote, even if the TLB entry is
    // aligned, writing from an address that's not aligned will result in
    // databeats with broken keep.
    assert((reinterpret_cast<uintptr_t>(curr_ptr) % 64) == 0);
    sg.addr = curr_ptr;
    sg.len = input_size;
    sg.stream = coyote::STRM_HOST;
    sg.dest = decoder_;

    auto last_transfer = off + coyote::MAX_TRANSFER_SIZE >= buffer->size;
    cthread_->invoke(coyote::CoyoteOper::LOCAL_READ, sg, last_transfer);
  }
  Profiler::close_regions({prefix + "enqueue_stream_input"});
}

} // namespace parcore
