#pragma once

#include <parcore/metadata/metadata.hpp>

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace parcore {

constexpr const uint64_t COLUMN_CHUNK_DECODER_CONFIG_ID = 0x5c19f934407065bd;

// Read-side register layout of the ColumnChunkDecoderConfig: a few info
// registers followed by 8 profiling counters per decoder (4 input + 4 output).
constexpr const uint32_t COLUMN_CHUNK_DECODER_INFO_REGS    = 3;
constexpr const uint32_t COLUMN_CHUNK_DECODER_PROFILE_REGS = 8;

struct StreamProfile {
    uint64_t handshakes_cycles;
    uint64_t starved_cycles;
    uint64_t stalled_cycles;
    uint64_t idle_cycles;
};

struct DecoderProfile {
    StreamProfile in;
    StreamProfile out;
};

class ColumnChunkDecoderConfig : public libstf::Config {
  public:
    ColumnChunkDecoderConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                             uint32_t num_regs);

    /**
     * Reads the input and output StreamProfiler counters for the given decoder.
     *
     * @param decoder The decoder whose profiling counters to read.
     */
    DecoderProfile read_profile(libstf::stream_t decoder);

    /**
     * Configures the ColumnChunkDecoder to process the provided column chunk.
     *
     * @param decoder        The decoder to configure.
     * @param compression    Whether this chunk is SNAPPY compressed or not.
     * @param num_values     The total number of values in this chunk.
     * @param typ            The type of values in this chunk.
     * @param has_def_levels Whether this chunk's data pages carry a definition-level section, i.e.
     *                       whether the column's Parquet schema has max_definition_level > 0.
     * @param has_rep_levels Whether this chunk's data pages carry a repetition-level section, i.e.
     *                       whether the column's Parquet schema has max_repetition_level > 0.
     */
    void enqueue_column_chunk(libstf::stream_t decoder, metadata::Compression compression,
                              uint64_t num_values, libstf::type_t typ, bool has_def_levels,
                              bool has_rep_levels);

    const libstf::stream_t num_decoders() const;
    const size_t           maximum_num_enqueued_configs() const;

    static constexpr uint64_t ID = COLUMN_CHUNK_DECODER_CONFIG_ID;

  private:
    libstf::stream_t num_decoders_;
    size_t           maximum_num_enqueued_configs_;
};

} // namespace parcore
