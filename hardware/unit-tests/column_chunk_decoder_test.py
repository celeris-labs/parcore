from dataclasses import dataclass
from typing import Optional
from coyote_test import fpga_stream, io_writer
from os.path import dirname, realpath, join

import pyarrow.parquet as pq

from page_header_parser_test import (
    _make_data_page_header,
    _make_dict_page_header,
    _extract_parquet_column_chunks,
)

from libstf_utils.configured_test_case import ConfiguredTestCase
from parcore_utils.fpga_configuration import ColumnChunkDecoderConfig, Compression


@dataclass
class _ColumnChunk:
    compression: bool
    num_values: int
    chunk_bytes: bytearray   # full column-chunk: thrift headers + payloads concatenated
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64
    is_required: bool = False  # REQUIRED columns have no definition levels in their data pages
    # Type the decoder casts the values to, None for stream_type (no cast)
    logical_type: Optional["fpga_stream.StreamType"] = None
    defer_dict_decoding: bool = False

    def output_type(self) -> "fpga_stream.StreamType":
        if self.defer_dict_decoding:
            return fpga_stream.StreamType.UNSIGNED_INT_8
        return self.logical_type if self.logical_type is not None else self.stream_type


def read_bytes(filename: str) -> bytearray:
    dir = dirname(realpath(__file__))
    with open(join(dir, 'data', filename), 'rb') as f:
        return bytearray(f.read())


# -- Parquet-backed cases ----------------------------------------------------
#
# For the parquet-backed workloads we lift the full thrift-wrapped column chunk
# (headers + SNAPPY-compressed payloads) directly from the parquet file. The
# pre-stripped *_chunk_compressed.bin / *_dict_compressed.bin fixtures are no
# longer needed.
def _parquet_chunk(parquet_filename: str, col_idx: int = 0) -> _ColumnChunk:
    path = join(dirname(realpath(__file__)), 'data', parquet_filename)
    pf = pq.ParquetFile(path)
    col_meta = pf.metadata.row_group(0).column(col_idx)
    cases = _extract_parquet_column_chunks(path)
    case = cases[col_idx]

    return _ColumnChunk(
        compression=True,  # all generated parquet fixtures use SNAPPY
        num_values=col_meta.num_values,
        chunk_bytes=case.chunk_bytes,
    )


# -- Synthetic PLAIN-only chunk ---------------------------------------------

def _make_def_levels(num_values: int) -> bytes:
    # RLE/bit-packing hybrid, bit_width=1, all values = 1 (all present)
    # RLE run header: (num_values << 1) | 0 encoded as varint, then value byte 0x01
    header = num_values << 1
    varint = []
    v = header
    while True:
        b = v & 0x7f
        v >>= 7
        if v:
            varint.append(b | 0x80)
        else:
            varint.append(b)
            break
    rle_body = bytes(varint) + bytes([0x01])
    return len(rle_body).to_bytes(4, 'little') + rle_body


def make_plain_data(items: list[int], is_required: bool = False) -> _ColumnChunk:
    stream = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_64, items)
    values = stream.data_to_bytearray()
    def_levels = b'' if is_required else _make_def_levels(len(items))
    payload = bytearray(def_levels) + bytearray(values)
    hdr = _make_data_page_header(
        num_values=len(items),
        uncompressed_size=len(payload),
        compressed_size=len(payload),
        encoding=0,  # PLAIN
    )
    chunk = bytearray(hdr) + payload
    return _ColumnChunk(
        compression=False,
        num_values=len(items),
        chunk_bytes=chunk,
        is_required=is_required,
    )


# -- Synthetic "tricky" chunk: dict + repeated decompressed-hybrid pages [+ plain]
#
# The dictionary body holds the actual values at the column's width, so it is
# synthesised at the column's width. The HYBRID body, by contrast, encodes
# dictionary *indices* and is therefore width-independent — we reuse the on-disk
# fixture for both 32- and 64-bit chunks. `dict_values` must match the values the
# fixture's indices point at (the `*_dict_decompressed.bin` fixtures store
# range(10, 20), i.e. 10 distinct values).
def make_tricky(
    filename: str,
    num_values: int,
    items: list[int],
    factor: int,
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64,
    dict_values: list[int] = list(range(10, 20)),
    trailing_plain: bool = True,
    is_required: bool = False,
) -> _ColumnChunk:
    hybrid_body = read_bytes(filename + '_chunk_decompressed.bin')
    if is_required:
        # REQUIRED column: drop the 4-byte length prefix + def_levels, keeping bit_width + runs.
        hybrid_body = hybrid_body[int.from_bytes(hybrid_body[:4], 'little') + 4:]

    chunk = bytearray()

    # Dictionary page: encoding=PLAIN, values at the column's width.
    dict_body = bytearray(fpga_stream.Stream(stream_type, dict_values).data_to_bytearray())
    chunk += _make_dict_page_header(
        num_values=len(dict_values),
        uncompressed_size=len(dict_body),
        compressed_size=len(dict_body),
    )
    chunk += dict_body

    # `factor` HYBRID pages. Unless the column is REQUIRED, each body carries its
    # 4-byte def_levels length prefix + def_levels + RLE/BPE-encoded payload,
    # which HybridPageDecoder skips at runtime.
    for _ in range(factor):
        chunk += _make_data_page_header(
            num_values=num_values,
            uncompressed_size=len(hybrid_body),
            compressed_size=len(hybrid_body),
            encoding=8,  # RLE_DICTIONARY
        )
        chunk += hybrid_body

    total_num_values = num_values * factor

    # Optional trailing PLAIN page. Its presence is what forces the dictionary
    # path to be reset via the injected dummy beat (see ColumnChunkDecoder).
    if trailing_plain:
        plain_values = fpga_stream.Stream(stream_type, items).data_to_bytearray()
        plain_def_levels = b'' if is_required else _make_def_levels(len(items))
        plain_body = bytearray(plain_def_levels) + bytearray(plain_values)
        chunk += _make_data_page_header(
            num_values=len(items),
            uncompressed_size=len(plain_body),
            compressed_size=len(plain_body),
            encoding=0,  # PLAIN
        )
        chunk += plain_body
        total_num_values += len(items)

    return _ColumnChunk(
        compression=False,
        num_values=total_num_values,
        chunk_bytes=chunk,
        stream_type=stream_type,
        is_required=is_required,
    )


# Reference outputs shared across cases.
def _rle_output(dict_values: list[int]) -> list[int]:
    # The rle_data fixture repeats dictionary index i - 10 for i in range(10, 20) i times
    return [dict_values[i - 10] for i in range(10, 20) for _ in range(i)]

_RLE_OUTPUT = _rle_output(list(range(10, 20)))
_PLAIN_OUTPUT = list(range(0, 256))


def _deferred_dict_output(
    dict_values: list[int], values: list[int], stream_type: "fpga_stream.StreamType"
) -> list[int]:
    """
    The output bytes of a defer_dict_decoding chunk: The dictionary's values, followed by the index
    of every value, 1, 2 or 4 bytes wide for up to 256, 65,536 or more dictionary entries. A value's
    index is the first dictionary entry that equals it.
    """
    index_width = 1 if len(dict_values) <= 256 else 2 if len(dict_values) <= 65536 else 4
    first_index = {}
    for i, v in enumerate(dict_values):
        first_index.setdefault(v, i)
    output = bytearray(fpga_stream.Stream(stream_type, dict_values).data_to_bytearray())
    for v in values:
        output += first_index[v].to_bytes(index_width, 'little')
    return list(output)


class ColumnChunkDecoderTestCase(ConfiguredTestCase):
    alternative_vfpga_top_file = "vfpga_tops/column_chunk_decoder_test.sv"
    debug_mode = True

    def configure(self):
        # Chunk-level configuration only — page-level configuration is produced
        # inside ColumnChunkDecoder by PageHeaderParser.
        config = self.config.get_config(ColumnChunkDecoderConfig)
        for input in self.inputs:
            compression = Compression.SNAPPY if input.compression else Compression.RAW
            config.enqueue_column_chunk(
                0, compression, input.num_values, input.stream_type, input.is_required,
                input.logical_type, input.defer_dict_decoding
            )

        # One stream input per column chunk (full thrift-wrapped bytes).
        for input in self.inputs:
            self.set_stream_input(0, input.chunk_bytes)

        # The output value width follows each chunk's logical type.
        for input, output in zip(self.inputs, self.outputs):
            self.set_expected_output(0, fpga_stream.Stream(input.output_type(), output))

    def finish_input(self, end_event):
        # Reads the profile once all outputs were written, while the simulation is still running.
        if self.read_profile_after_run:
            self.get_io_writer().block_till_completed(
                io_writer.CoyoteOperator.LOCAL_WRITE,
                self._expected_completed_write_transfers,
                end_event,
            )
            self.profile = self.config.get_config(ColumnChunkDecoderConfig).read_profile(0)

        super().finish_input(end_event)

    def run_chunks(self, inputs: list[_ColumnChunk], outputs: list[list[int]],
                   read_profile: bool = False):
        """Drive the decoder with one or more column chunks and assert outputs."""
        self.inputs = inputs
        self.outputs = outputs
        self.read_profile_after_run = read_profile

        self.simulate_fpga()
        self.assert_simulation_output()

    def test_one_rle_page(self):
        self.run_chunks([_parquet_chunk('rle_data.parquet')], [_RLE_OUTPUT])

    def test_profile(self):
        self.run_chunks(
            [_parquet_chunk('rle_data.parquet'), _parquet_chunk('bpe_data.parquet')],
            [_RLE_OUTPUT, list(range(10, 20)) * 15],
            read_profile=True,
        )

        # Every column chunk is one input and one output stream.
        self.assertEqual(self.profile.input.last_handshakes, 2)
        self.assertEqual(self.profile.output.last_handshakes, 2)
        self.assertGreater(self.profile.input.handshakes_cycles, 0)
        self.assertGreater(self.profile.output.handshakes_cycles, 0)

    def test_one_bpe_page(self):
        self.run_chunks([_parquet_chunk('bpe_data.parquet')], [list(range(10, 20)) * 15])

    def test_one_mixed_page(self):
        output = ([i**8 for i in range(10, 20) for _ in range(i)] +
                  list(range(128, 256)) * 2) * 2
        self.run_chunks([_parquet_chunk('mixed_data.parquet')], [output])

    def test_one_big_bpe_page(self):
        self.run_chunks([_parquet_chunk('big_bpe_data.parquet')], [list(range(10, 100)) * 5])

    def test_plain_page(self):
        self.run_chunks([make_plain_data(_PLAIN_OUTPUT)], [_PLAIN_OUTPUT])

    def test_tricky_page(self):
        factor = 3
        tricky = make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, factor)
        self.run_chunks(
            [tricky, _parquet_chunk('rle_data.parquet')],
            [_RLE_OUTPUT * factor + _PLAIN_OUTPUT, _RLE_OUTPUT],
        )

    def test_many_hybrid_pages(self):
        mixed_output = ([i**8 for i in range(10, 20) for _ in range(i)] +
                        list(range(128, 256)) * 2) * 2
        self.run_chunks(
            [
                _parquet_chunk('rle_data.parquet'),
                _parquet_chunk('bpe_data.parquet'),
                _parquet_chunk('mixed_data.parquet'),
                _parquet_chunk('big_bpe_data.parquet'),
            ],
            [
                _RLE_OUTPUT,
                list(range(10, 20)) * 15,
                mixed_output,
                list(range(10, 100)) * 5,
            ],
        )

    def test_plain_after_hybrid(self):
        chunk = make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1)
        self.run_chunks([chunk], [_RLE_OUTPUT + _PLAIN_OUTPUT])

    def test_different_types(self):
        # Back-to-back chunks exercising the TypedDictionary reset across a chunk
        # boundary AND a width switch:
        #   Chunk A: 32-bit, dict + HYBRID + trailing PLAIN. The trailing PLAIN
        #            page (with a dict page seen) triggers the injected dummy
        #            reset beat that flushes the internal Dictionary cache.
        #   Chunk B: 64-bit, dict + HYBRID (no PLAIN). It reloads the dictionary
        #            from scratch. If chunk A's reset did not fully clear the
        #            dictionary state, chunk B would either materialise stale
        #            32-bit values or mis-size its 64-bit output, so a correct
        #            chunk B output proves the reset.
        chunk_a = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1,
            stream_type=fpga_stream.StreamType.SIGNED_INT_32,
        )
        chunk_b = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), [], 1,
            stream_type=fpga_stream.StreamType.SIGNED_INT_64,
            trailing_plain=False,
        )
        self.run_chunks(
            [chunk_a, chunk_b],
            [_RLE_OUTPUT + _PLAIN_OUTPUT, _RLE_OUTPUT],
        )

    def test_required_plain_page(self):
        self.run_chunks([make_plain_data(_PLAIN_OUTPUT, is_required=True)], [_PLAIN_OUTPUT])

    def test_required_tricky_page(self):
        tricky = make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 2,
                             is_required=True)
        self.run_chunks([tricky], [_RLE_OUTPUT * 2 + _PLAIN_OUTPUT])

    def test_required_and_optional_chunks(self):
        # The flag is per chunk: alternate REQUIRED and OPTIONAL chunks back to back, covering both
        # the hybrid and the plain (StripLevels) path.
        self.run_chunks(
            [
                make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1,
                            is_required=True),
                make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1),
                make_plain_data(_PLAIN_OUTPUT, is_required=True),
                _parquet_chunk('rle_data.parquet'),
            ],
            [
                _RLE_OUTPUT + _PLAIN_OUTPUT,
                _RLE_OUTPUT + _PLAIN_OUTPUT,
                _PLAIN_OUTPUT,
                _RLE_OUTPUT,
            ],
        )

    def test_logical_types(self):
        # Back-to-back chunks cast to narrower logical types, covering dictionary, hybrid and plain
        # pages of OPTIONAL and REQUIRED columns, followed by a 64-bit chunk without a cast. The
        # INT16 values are negative and use both bytes to catch byte selection and sign errors.
        int16_dict  = [-1000 + 237 * i for i in range(10)]
        int16_plain = list(range(-1000, 1000, 7))

        int16_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), int16_plain, 1,
            stream_type=fpga_stream.StreamType.SIGNED_INT_32, dict_values=int16_dict,
        )
        int16_chunk.logical_type = fpga_stream.StreamType.SIGNED_INT_16

        uint8_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 2,
            stream_type=fpga_stream.StreamType.SIGNED_INT_32, is_required=True,
        )
        uint8_chunk.logical_type = fpga_stream.StreamType.UNSIGNED_INT_8

        self.run_chunks(
            [int16_chunk, uint8_chunk, make_plain_data(_PLAIN_OUTPUT)],
            [
                _rle_output(int16_dict) + int16_plain,
                _RLE_OUTPUT * 2 + _PLAIN_OUTPUT,
                _PLAIN_OUTPUT,
            ],
        )

    def test_logical_type_int32_from_int64(self):
        # INT64 chunks cast to INT32: a dictionary chunk with hybrid and plain pages and a REQUIRED
        # plain chunk with a partial last beat, followed by an INT64 chunk without a cast. The values
        # cover the whole INT32 range, including both ends and negative values.
        int32_dict  = [-2**31, -1, 0, 1, 2**31 - 1, -123456789, 987654321, -7, 65536, -65537]
        int32_plain = list(range(-2**31, 2**31, 2**31 // 50))

        dict_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), int32_plain, 2, dict_values=int32_dict,
        )
        dict_chunk.logical_type = fpga_stream.StreamType.SIGNED_INT_32

        plain_values = [-2**31 + 3 * i for i in range(37)]
        plain_chunk = make_plain_data(plain_values, is_required=True)
        plain_chunk.logical_type = fpga_stream.StreamType.SIGNED_INT_32

        self.run_chunks(
            [dict_chunk, plain_chunk, make_plain_data(_PLAIN_OUTPUT)],
            [
                _rle_output(int32_dict) * 2 + int32_plain,
                plain_values,
                _PLAIN_OUTPUT,
            ],
        )

    def test_logical_types_from_int64(self):
        # INT64 chunks cast to INT16 and UINT8, which the decoder does in two steps (64 -> 32 bit on
        # the dictionary and plain paths, then to the logical type at the output): an OPTIONAL
        # dictionary chunk with hybrid and plain pages, a REQUIRED one, and a REQUIRED plain chunk
        # with a partial last beat, followed by an INT64 chunk without a cast. The INT16 values cover
        # both ends of the range.
        int16_dict  = [-2**15, -1, 0, 1, 2**15 - 1, -12345, 23456, -7, 256, -257]
        int16_plain = list(range(-2**15, 2**15, 2**15 // 40))

        int16_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), int16_plain, 2, dict_values=int16_dict,
        )
        int16_chunk.logical_type = fpga_stream.StreamType.SIGNED_INT_16

        uint8_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1, is_required=True,
        )
        uint8_chunk.logical_type = fpga_stream.StreamType.UNSIGNED_INT_8

        plain_values = [-2**15 + 5 * i for i in range(45)]
        plain_chunk = make_plain_data(plain_values, is_required=True)
        plain_chunk.logical_type = fpga_stream.StreamType.SIGNED_INT_16

        self.run_chunks(
            [int16_chunk, uint8_chunk, plain_chunk, make_plain_data(_PLAIN_OUTPUT)],
            [
                _rle_output(int16_dict) * 2 + int16_plain,
                _RLE_OUTPUT + _PLAIN_OUTPUT,
                plain_values,
                _PLAIN_OUTPUT,
            ],
        )

    def test_defer_dict_decoding(self):
        # Chunks that emit their dictionary and indices: 1-byte indices for a 64-bit OPTIONAL chunk,
        # 2-byte and 4-byte indices for REQUIRED 32-bit chunks whose dictionaries have more than 256
        # and 65,536 entries, and SNAPPY-compressed chunks from Parquet files. Value chunks before,
        # in between and after check that the decoder switches between the modes.
        int64_dict = [-2**63, -1, 0, 1, 2**63 - 1, -123456789012, 98765432109, -7, 65536, -65537]
        int64_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), [], 2, dict_values=int64_dict, trailing_plain=False,
        )
        int64_chunk.defer_dict_decoding = True

        int16_index_dict = [3 * i - 1000 for i in range(300)]
        int16_index_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), [], 1,
            stream_type=fpga_stream.StreamType.SIGNED_INT_32, dict_values=int16_index_dict,
            trailing_plain=False, is_required=True,
        )
        int16_index_chunk.defer_dict_decoding = True

        int32_index_dict = list(range(70000))
        int32_index_chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), [], 1,
            stream_type=fpga_stream.StreamType.SIGNED_INT_32, dict_values=int32_index_dict,
            trailing_plain=False, is_required=True,
        )
        int32_index_chunk.defer_dict_decoding = True

        rle_chunk = _parquet_chunk('rle_data.parquet')
        rle_chunk.defer_dict_decoding = True

        mixed_output = ([i**8 for i in range(10, 20) for _ in range(i)] +
                        list(range(128, 256)) * 2) * 2
        mixed_chunk = _parquet_chunk('mixed_data.parquet')
        mixed_chunk.defer_dict_decoding = True

        int64 = fpga_stream.StreamType.SIGNED_INT_64
        int32 = fpga_stream.StreamType.SIGNED_INT_32
        self.run_chunks(
            [
                make_tricky('rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1),
                int64_chunk,
                int16_index_chunk,
                make_plain_data(_PLAIN_OUTPUT),
                int32_index_chunk,
                rle_chunk,
                _parquet_chunk('rle_data.parquet'),
                mixed_chunk,
            ],
            [
                _RLE_OUTPUT + _PLAIN_OUTPUT,
                _deferred_dict_output(int64_dict, _rle_output(int64_dict) * 2, int64),
                _deferred_dict_output(int16_index_dict, _rle_output(int16_index_dict), int32),
                _PLAIN_OUTPUT,
                _deferred_dict_output(int32_index_dict, _rle_output(int32_index_dict), int32),
                _deferred_dict_output(list(range(10, 20)), _RLE_OUTPUT, int64),
                _RLE_OUTPUT,
                _deferred_dict_output(list(dict.fromkeys(mixed_output)), mixed_output, int64),
            ],
        )
