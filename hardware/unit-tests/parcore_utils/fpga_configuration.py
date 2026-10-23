# Python counterpart of software/parcore/configuration.hpp and of the configurations in
# hardware/src/hdl/config, built on libstf's configuration utils. Keep the register encodings in
# sync with the C++ implementation and the hardware.
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional, Union
from coyote_test import fpga_stream
from libstf_utils.fpga_configuration import Config, RegisterAccess, stream_type_to_libstf_type_t


# libstf has no string type, so german strings travel as its 128 bit type (INT128_T). Matches
# GERMAN_STR_T in hardware/src/hdl/common.sv.
GERMAN_STR_T = 6


def to_type_t(data_type: Union[fpga_stream.StreamType, int]) -> int:
    """
    The type_t of data_type. Types without a StreamType, i.e., GERMAN_STR_T, are passed as type_t.
    """
    return data_type if isinstance(data_type, int) else stream_type_to_libstf_type_t(data_type)


class Compression(IntEnum):
    """
    Hardware encoding of compression_t (hardware/src/hdl/common.sv).
    """
    RAW    = 0
    SNAPPY = 1


@dataclass
class StreamProfile:
    handshakes_cycles: int
    starved_cycles: int
    stalled_cycles: int
    idle_cycles: int
    last_handshakes: int # Handshakes with last set, i.e., completed streams


@dataclass
class DecoderProfile:
    input: StreamProfile
    output: StreamProfile


class ColumnChunkDecoderConfig(Config):
    """
    Configures the column chunks the ColumnChunkDecoders process.
    """

    ID = 0x5c19f934407065bd # COLUMN_CHUNK_DECODER_CONFIG_ID

    # Read registers: info registers followed by the StreamProfiler counters of each decoder
    INFO_REGS    = 3
    PROFILE_REGS = 10

    # column_chunk_conf_t packs (MSB -> LSB) as:
    #   logical type_t [3 bits] | is_required [1 bit] | compression_t [1 bit] |
    #   num_values [32 bits] | type_t [3 bits]
    # in register 2 * decoder. The string heap address does not fit, so GERMAN_STR_T chunks write it
    # to register 2 * decoder + 1.
    NUM_VALUES_SHIFT   = 3
    COMPRESSION_SHIFT  = NUM_VALUES_SHIFT + 32
    IS_REQUIRED_SHIFT  = COMPRESSION_SHIFT + 1
    LOGICAL_TYPE_SHIFT = IS_REQUIRED_SHIFT + 1

    def __init__(self, registers: RegisterAccess, addr_offset: int, num_regs: int):
        super().__init__(registers, addr_offset, num_regs)
        self.num_decoders = self.read_register(1)
        self.maximum_num_enqueued_configs = self.read_register(2)

    @staticmethod
    def register_value(
        compression: Compression,
        num_values: int,
        data_type: Union[fpga_stream.StreamType, int],
        is_required: bool = False,
        logical_type: Optional[Union[fpga_stream.StreamType, int]] = None,
    ) -> int:
        assert 0 <= num_values < pow(2, 32)
        # The hardware always uses the logical type, so it is written even if it equals data_type
        if logical_type is None:
            logical_type = data_type
        logical_type_t = to_type_t(logical_type)
        return (
            logical_type_t << ColumnChunkDecoderConfig.LOGICAL_TYPE_SHIFT
            | int(is_required) << ColumnChunkDecoderConfig.IS_REQUIRED_SHIFT
            | compression << ColumnChunkDecoderConfig.COMPRESSION_SHIFT
            | num_values << ColumnChunkDecoderConfig.NUM_VALUES_SHIFT
            | to_type_t(data_type)
        )

    def enqueue_column_chunk(
        self,
        decoder: int,
        compression: Compression,
        num_values: int,
        data_type: Union[fpga_stream.StreamType, int],
        is_required: bool = False,
        logical_type: Optional[Union[fpga_stream.StreamType, int]] = None,
        string_heap_addr: int = 0,
    ):
        """
        Configures the given decoder to process a column chunk of num_values values of data_type.
        is_required is set for REQUIRED columns (max_definition_level == 0), whose data pages carry
        no definition levels. The decoder casts the values to logical_type, which defaults to
        data_type (no cast). GERMAN_STR_T chunks write the strings that do not fit inline to the
        heap buffer at string_heap_addr.
        """
        assert decoder < self.num_decoders, (
            f"Attempted to configure ColumnChunkDecoder {decoder} out of {self.num_decoders}"
        )
        self.write_register(
            2 * decoder,
            ColumnChunkDecoderConfig.register_value(
                compression, num_values, data_type, is_required, logical_type
            ),
        )
        # Writing it for any other type would desynchronise the two configuration FIFOs, since the
        # hardware only pops it for GERMAN_STR_T.
        if to_type_t(data_type) == GERMAN_STR_T:
            self.write_register(2 * decoder + 1, string_heap_addr)

    def read_profile(self, decoder: int) -> DecoderProfile:
        """
        Reads the input and output StreamProfiler counters of the given decoder. Reading the last
        counter resets the profilers once the next stream starts.
        """
        assert decoder < self.num_decoders, (
            f"Attempted to read profile of ColumnChunkDecoder {decoder} out of {self.num_decoders}"
        )
        base = self.INFO_REGS + decoder * self.PROFILE_REGS
        counters = [self.read_register(base + i) for i in range(self.PROFILE_REGS)]
        return DecoderProfile(StreamProfile(*counters[:5]), StreamProfile(*counters[5:]))


class RunDecoderConfig(Config):
    """
    Configures a RunDecoder that is used on its own, e.g., in the RunDecoder unit-test design.
    """

    ID = 0xd6736a190f91fa01 # RUN_DECODER_CONFIG_ID

    def __init__(self, registers: RegisterAccess, addr_offset: int, num_regs: int):
        super().__init__(registers, addr_offset, num_regs)
        self.maximum_num_enqueued_configs = self.read_register(1)

    def enqueue_page(self, bit_width: int, offset: int, num_values: int):
        """
        Configures the RunDecoder for one page: the bit width of the encoded values, the byte offset
        at which the RLE/BPE body starts and the number of values to decode.
        """
        self.write_register(0, bit_width)
        self.write_register(1, offset)
        self.write_register(2, num_values)


class HybridPageDecoderConfig(Config):
    """
    Configures a HybridPageDecoder that is used on its own, e.g., in its unit-test design.
    """

    ID = 0xd6736a4eef933024 # HYBRID_PAGE_DECODER_CONFIG_ID

    # hybrid_page_conf_t packs (MSB -> LSB) as: is_required [1 bit] | num_values [32 bits]
    IS_REQUIRED_SHIFT = 32

    def enqueue_page(self, num_values: int, is_required: bool = False):
        """
        Configures the HybridPageDecoder to decode num_values values from the next page. Pages of
        REQUIRED columns (is_required) have no definition levels.
        """
        assert 0 <= num_values < pow(2, 32)
        self.write_register(0, int(is_required) << self.IS_REQUIRED_SHIFT | num_values)
