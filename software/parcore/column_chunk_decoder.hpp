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

  // With string decoders, values are on 2I and the string heap on 2I + 1. The
  // heap stays completely silent for anything that is not a BYTE_ARRAY column,
  // so no transfer and no interrupt are raised on it there.
  [[nodiscard]] libstf::stream_t values_stream() const;
  [[nodiscard]] libstf::stream_t heap_stream() const;

  struct Handle {
  public:
    Handle(std::shared_ptr<ColumnChunkDecoder> column_chunk_decoder,
           std::unique_lock<std::mutex> lock,
           std::shared_ptr<libstf::OutputHandle> output_handle);

    void add_chunk(const std::shared_ptr<libstf::Buffer> &buffer);

    // The && qualifier means this can only be called on a moving handle
    std::shared_ptr<libstf::OutputHandle> done() &&;

  private:
    std::shared_ptr<ColumnChunkDecoder> column_chunk_decoder_;
    std::unique_lock<std::mutex> lock_;

    std::shared_ptr<libstf::OutputHandle> output_handle_;
    bool chunk_written_;
  };

  /**
   * Configures the decoder for the column chunk. The OutputBufferManager places
   * the output, so the heap of a string chunk can span several of its buffers.
   * The german_str_t records of strings longer than 12 bytes therefore hold the
   * offset of the string in the chunk's heap output instead of a pointer.
   * Software that places the heap itself configures its address with
   * ColumnChunkDecoderConfig::enqueue_column_chunk to get pointers.
   *
   * With defer_dict_decoding, the decoder emits the dictionary page's values
   * (german_str_t records for strings, whose long strings go to the heap)
   * followed by one index per value: 1, 2 or 4 bytes for up to 256, 65,536 or
   * more dictionary entries. Every data page of the chunk must then be
   * dictionary encoded.
   */
  [[nodiscard]] std::unique_ptr<Handle>
  decode_column_chunk(const metadata::ColumnChunk &column_chunk,
                      bool defer_dict_decoding = false);

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

  // The streams the chunk's output is written to. Only string chunks write to
  // the heap stream, so waiting on it for other chunks would hang.
  libstf::stream_mask_t output_streams(const metadata::ColumnChunk &column_chunk) const;

  void enqueue_stream_input(const std::shared_ptr<libstf::Buffer> &buffer);
};

} // namespace parcore
