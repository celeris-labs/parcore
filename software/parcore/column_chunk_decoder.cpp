#include <libstf/profiling.hpp>
#include <parcore/column_chunk_decoder.hpp>

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

std::unique_ptr<ColumnChunkDecoder::Handle>
ColumnChunkDecoder::decode_column_chunk(
    const metadata::ColumnChunk &column_chunk) {
  std::unique_lock lock(mtx);
  Profiler::open_regions({prefix + "decode_column_chunk"});
  assert(column_chunk_enqueued_configs_ + 1 <
         column_chunk_config_->maximum_num_enqueued_configs());

  auto output_handle =
      output_buffer_manager_->acquire_output_handle(decoder_mask());

  auto type = metadata::to_libstf_type(column_chunk.type);
  column_chunk_config_->enqueue_column_chunk(
      decoder_, column_chunk.compression, column_chunk.num_values, type,
      column_chunk.has_def_levels, column_chunk.has_rep_levels);

  column_chunk_enqueued_configs_ += 1;

  Profiler::close_regions({prefix + "decode_column_chunk"});
  return std::make_unique<Handle>(shared_from_this(), std::move(lock),
                                  output_handle);
}

void ColumnChunkDecoder::finished_decoding_column_chunk(
    const metadata::ColumnChunk &column_chunk) {
  std::unique_lock lock(mtx);
  column_chunk_enqueued_configs_ -= 1;
}

libstf::stream_mask_t ColumnChunkDecoder::decoder_mask() const {
  libstf::stream_mask_t mask;
  mask.set(decoder_);
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
