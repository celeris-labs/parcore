#include <cstring>

#include <libstf/profiling.hpp>
#include <parcore/configuration.hpp>
#include <parcore/metadata/metadata.hpp>
#include <sstream>
#include <stdexcept>
#include <string>

using libstf::Profiler;

namespace parcore {

inline uint64_t compression_to_hardware(metadata::Compression compression) {
    switch (compression) {
    case metadata::Compression::RAW:
        return 0;
    case metadata::Compression::SNAPPY:
        return 1;
    default: {
        std::ostringstream msg;
        msg << "Cannot convert compression scheme '" << compression
            << "' to hardware encoding: Only RAW (0) and SNAPPY (1) are supported by ParCore.";
        throw std::runtime_error(msg.str());
    }
    }
}

// column_chunk_conf_t packs (MSB -> LSB) as:
//   has_rep_levels [1 bit] | has_def_levels [1 bit] | compression_t [1 bit] | num_values [32 bits]
//   | type_t [3 bits]
constexpr const uint32_t COLUMN_CHUNK_DECODER_NUM_VALUES_SHIFT = 3;
constexpr const uint32_t COLUMN_CHUNK_DECODER_COMPRESSION_SHIFT =
    COLUMN_CHUNK_DECODER_NUM_VALUES_SHIFT + 32;
constexpr const uint32_t COLUMN_CHUNK_DECODER_HAS_DEF_LEVELS_SHIFT =
    COLUMN_CHUNK_DECODER_COMPRESSION_SHIFT + 1;
constexpr const uint32_t COLUMN_CHUNK_DECODER_HAS_REP_LEVELS_SHIFT =
    COLUMN_CHUNK_DECODER_HAS_DEF_LEVELS_SHIFT + 1;

const std::string column_config_prefix = "parcore::ColumnChunkDecoderConfig::";

ColumnChunkDecoderConfig::ColumnChunkDecoderConfig(std::shared_ptr<coyote::cThread> cthread,
                                                   uint32_t addr_offset, uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_decoders_(read_register(1).value()),
      maximum_num_enqueued_configs_(read_register(2).value()) {}

void ColumnChunkDecoderConfig::enqueue_column_chunk(libstf::stream_t      decoder,
                                                    metadata::Compression compression,
                                                    uint64_t num_values, libstf::type_t typ,
                                                    bool has_def_levels, bool has_rep_levels) {
    if (decoder >= num_decoders_) {
        throw std::runtime_error("attempted to configure ColumnChunkDecoder " +
                                 std::to_string(decoder) + " (zero-based numbering), out of " +
                                 std::to_string(num_decoders_) + " decoders");
    }

    Profiler::open_regions({column_config_prefix + "enqueue_column_chunk"});
    uint64_t packed =
        (static_cast<uint64_t>(has_rep_levels ? 1 : 0) << COLUMN_CHUNK_DECODER_HAS_REP_LEVELS_SHIFT) |
        (static_cast<uint64_t>(has_def_levels ? 1 : 0) << COLUMN_CHUNK_DECODER_HAS_DEF_LEVELS_SHIFT) |
        (compression_to_hardware(compression) << COLUMN_CHUNK_DECODER_COMPRESSION_SHIFT) |
        ((num_values & 0xFFFFFFFF) << COLUMN_CHUNK_DECODER_NUM_VALUES_SHIFT) |
        (static_cast<uint64_t>(typ) & 0x7);
    write_register(libstf::ConfigRegister(decoder, packed));
    Profiler::close_regions({column_config_prefix + "enqueue_column_chunk"});
}

DecoderProfile ColumnChunkDecoderConfig::read_profile(libstf::stream_t decoder) {
    if (decoder >= num_decoders_) {
        throw std::runtime_error("Attempted to read profile of ColumnChunkDecoder " +
                                 std::to_string(decoder) + ", out of " +
                                 std::to_string(num_decoders_) + " decoders");
    }

    auto base = COLUMN_CHUNK_DECODER_INFO_REGS + decoder * COLUMN_CHUNK_DECODER_PROFILE_REGS;

    DecoderProfile profile;
    profile.in.handshakes_cycles  = read_register(base + 0).value();
    profile.in.starved_cycles     = read_register(base + 1).value();
    profile.in.stalled_cycles     = read_register(base + 2).value();
    profile.in.idle_cycles        = read_register(base + 3).value();
    profile.out.handshakes_cycles = read_register(base + 4).value();
    profile.out.starved_cycles    = read_register(base + 5).value();
    profile.out.stalled_cycles    = read_register(base + 6).value();
    profile.out.idle_cycles       = read_register(base + 7).value();
    return profile;
}

const libstf::stream_t ColumnChunkDecoderConfig::num_decoders() const { return num_decoders_; }

const size_t ColumnChunkDecoderConfig::maximum_num_enqueued_configs() const {
    return maximum_num_enqueued_configs_;
}

} // namespace parcore
