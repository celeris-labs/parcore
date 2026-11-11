#pragma once

#include <parcore/metadata/metadata.hpp>

#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace parcore {

constexpr const uint64_t COLUMN_CHUNK_DECODER_CONFIG_ID = 0x8ac238fba070fc46;

// Read-side register layout of the ColumnChunkDecoderConfig: a few info
// registers followed by 10 profiling counters per decoder (5 input + 5 output).
constexpr const uint32_t COLUMN_CHUNK_DECODER_INFO_REGS    = 4;
constexpr const uint32_t COLUMN_CHUNK_DECODER_PROFILE_REGS = 10;

struct StreamProfile {
    uint64_t handshakes_cycles;
    uint64_t starved_cycles;
    uint64_t stalled_cycles;
    uint64_t idle_cycles;
    uint64_t last_handshakes; // Number of handshakes with last set, i.e. completed streams
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
     * @param decoder          The decoder to configure.
     * @param compression      Whether this chunk is SNAPPY compressed or not.
     * @param num_values       The total number of values in this chunk.
     * @param typ              The physical type of values in this chunk.
     * @param is_required      Whether the column is REQUIRED (max_definition_level == 0), i.e. its
     *                         data pages carry no definition levels.
     * @param logical_typ      The type the decoder casts the values to. Pass typ for no cast.
     * @param defer_dict_decoding Whether the decoder emits the dictionary and the dictionary
     *                         indices instead of the values: The output is the dictionary page's
     *                         values (typ), followed by one index per value, 1 byte wide for up to
     *                         256 dictionary entries, 2 bytes for up to 65,536 and 4 bytes above.
     *                         logical_typ is ignored.
     * @param string_heap_addr Base address of the buffer receiving the string heap.
     *                         Only meaningful for GERMAN_STR_T, which needs string decoders;
     *                         ignored otherwise.
     *
     * @warning Only set defer_dict_decoding for chunks whose data pages are ALL
     *          dictionary-encoded, for example checked with the chunk's encoding_stats. A single
     *          PLAIN data page (such as a writer's fallback after its dictionary filled up) makes
     *          the hardware hang or emit corrupt output. The decoder does not detect this.
     */
    void enqueue_column_chunk(libstf::stream_t decoder, metadata::Compression compression,
                              uint64_t num_values, libstf::type_t typ, bool is_required,
                              libstf::type_t logical_typ, bool defer_dict_decoding = false,
                              uint64_t string_heap_addr = 0);

    /**
     * Whether the decoders can cast values of typ to logical_typ.
     */
    static bool supports_cast(libstf::type_t typ, libstf::type_t logical_typ);

    const libstf::stream_t num_decoders() const;

    /**
     * Whether the decoders decode strings. They then write their string heap on a second output
     * stream each.
     */
    bool has_string_decoders() const;
    const size_t           maximum_num_enqueued_configs() const;

    static constexpr uint64_t ID = COLUMN_CHUNK_DECODER_CONFIG_ID;

  private:
    libstf::stream_t num_decoders_;
    bool             has_string_decoders_;
    size_t           maximum_num_enqueued_configs_;
};

} // namespace parcore
