#pragma once

#include <memory>
#include <mutex>

#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>
#include <parcore/configuration.hpp>
#include <parcore/metadata/metadata.hpp>

namespace parcore {

class ColumnChunkDecoder
    : public std::enable_shared_from_this<ColumnChunkDecoder> {
public:
  ColumnChunkDecoder(
      std::shared_ptr<coyote::cThread> cthread,
      std::shared_ptr<libstf::TLBManager> tlb_manager,
      std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager,
      std::shared_ptr<ColumnChunkDecoderConfig> column_chunk_config,
      libstf::stream_t decoder);

  [[nodiscard]] const libstf::stream_t &decoder() const;

  // PairedOutputWriter gives every decoder two logical output streams sharing
  // one physical channel: values on 2I, the string heap on 2I + 1. The heap
  // stays completely silent for anything that is not a BYTE_ARRAY column, so no
  // transfer and no interrupt are raised on it there.
  [[nodiscard]] libstf::stream_t values_stream() const;
  [[nodiscard]] libstf::stream_t heap_stream() const;

  struct Handle {
  public:
    Handle(std::shared_ptr<ColumnChunkDecoder> column_chunk_decoder,
           std::unique_lock<std::mutex> lock,
           std::shared_ptr<libstf::OutputHandle> output_handle,
           uint64_t string_heap_address);

    void add_chunk(const std::shared_ptr<libstf::Buffer> &buffer);

    /**
     * Device address the string heap of this column chunk will be written to,
     * and the base the addresses inside its german_str_t records are relative
     * to. Zero for chunks that are not BYTE_ARRAY.
     */
    [[nodiscard]] uint64_t string_heap_address() const;

    // The && qualifier means this can only be called on a moving handle
    std::shared_ptr<libstf::OutputHandle> done() &&;

  private:
    std::shared_ptr<ColumnChunkDecoder> column_chunk_decoder_;
    std::unique_lock<std::mutex> lock_;

    std::shared_ptr<libstf::OutputHandle> output_handle_;
    uint64_t string_heap_address_;
    bool chunk_written_;
  };

  [[nodiscard]] std::unique_ptr<Handle>
  decode_column_chunk(const metadata::ColumnChunk &column_chunk);

  void
  finished_decoding_column_chunk(const metadata::ColumnChunk &column_chunk);

private:
  std::shared_ptr<coyote::cThread> cthread_;
  std::shared_ptr<libstf::TLBManager> tlb_manager_;
  std::shared_ptr<libstf::OutputBufferManager> output_buffer_manager_;
  std::shared_ptr<ColumnChunkDecoderConfig> column_chunk_config_;
  libstf::stream_t decoder_;

  std::mutex mtx;
  size_t column_chunk_enqueued_configs_;

  // The heap stream is only included for BYTE_ARRAY chunks; for anything else
  // the hardware never writes there, so waiting on it would hang.
  libstf::stream_mask_t decoder_mask(bool with_heap) const;

  void enqueue_stream_input(const std::shared_ptr<libstf::Buffer> &buffer);
};

} // namespace parcore
