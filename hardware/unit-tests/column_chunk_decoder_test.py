from dataclasses import dataclass
from coyote_test import fpga_test_case, fpga_stream, fpga_register, simulation_time
from os.path import dirname, realpath, join

import pyarrow.parquet as pq

from page_header_parser_test import (
    _make_data_page_header,
    _make_dict_page_header,
    _extract_parquet_column_chunks,
)

from libstf_utils.common import stream_type_to_libstf_type_t


@dataclass
class _ColumnChunk:
    compression: bool
    num_values: int
    chunk_bytes: bytearray   # full column-chunk: thrift headers + payloads concatenated
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64
    # Whether the data page bodies open with a definition-level and/or repetition-level length
    # prefix. The two are independent (wire format is [rep levels][def levels][values]). 
    # has_rep_levels is always False, since such complex columns are not yet supported.
    has_def_levels: bool = True
    has_rep_levels: bool = False

    def _register(self) -> bytearray:
        type_t = stream_type_to_libstf_type_t(self.stream_type)
        # column_chunk_conf_t packs (MSB -> LSB) as:
        #   has_rep_levels [1 bit] | has_def_levels [1 bit] | compression_t [1 bit]
        #   | num_values [32 bits] | type_t [3 bits]
        compression = 1 if self.compression else 0
        has_def_levels = 1 if self.has_def_levels else 0
        has_rep_levels = 1 if self.has_rep_levels else 0
        packed = ((has_rep_levels << 37) | (has_def_levels << 36) | (compression << 35) |
                  ((self.num_values & 0xFFFFFFFF) << 3) | (type_t & 0x7))
        return bytearray(packed.to_bytes(8, 'little'))


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


def _strip_levels_prefix(body: bytearray) -> bytearray:
    """Drop the 4-byte def-level length prefix and the level bytes it covers.

    Converts a fixture page body written for an OPTIONAL column into the body a
    REQUIRED column would have: bit_width/values first, with no prefix at all.
    """
    n = int.from_bytes(bytes(body[:4]), 'little')
    return bytearray(body[4 + n:])


def make_plain_data(items: list[int], has_def_levels: bool = True) -> _ColumnChunk:
    stream = fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_64, items)
    values = stream.data_to_bytearray()
    payload = bytearray(values)
    if has_def_levels:
        payload = bytearray(_make_def_levels(len(items))) + payload
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
        has_def_levels=has_def_levels,
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
    has_def_levels: bool = True,
) -> _ColumnChunk:
    hybrid_body = read_bytes(filename + '_chunk_decompressed.bin')
    if not has_def_levels:
        hybrid_body = _strip_levels_prefix(hybrid_body)

    chunk = bytearray()

    # Dictionary page: encoding=PLAIN, values at the column's width.
    dict_body = bytearray(fpga_stream.Stream(stream_type, dict_values).data_to_bytearray())
    chunk += _make_dict_page_header(
        num_values=len(dict_values),
        uncompressed_size=len(dict_body),
        compressed_size=len(dict_body),
    )
    chunk += dict_body

    # `factor` HYBRID pages. With has_def_levels the body carries its 4-byte
    # def_levels length prefix + def_levels + RLE/BPE-encoded payload, and
    # HybridPageDecoder skips the prefix to find the bit_width byte; without it
    # the body opens directly on the bit_width byte.
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
        plain_body = bytearray(plain_values)
        if has_def_levels:
            plain_body = bytearray(_make_def_levels(len(items))) + plain_body
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
        has_def_levels=has_def_levels,
    )


# Reference outputs shared across cases.
_RLE_OUTPUT = [i for i in range(10, 20) for _ in range(i)]
_PLAIN_OUTPUT = list(range(0, 256))


class ColumnChunkDecoderTestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga_tops/column_chunk_decoder_test.sv"
    debug_mode = True

    def __init__(self, a) -> None:
        super().__init__(a)

    def setUp(self):
        return super().setUp()

    def run_chunks(self, inputs: list[_ColumnChunk], outputs: list[list[int]]):
        """Drive the decoder with one or more column chunks and assert outputs."""
        # Chunk-level registers only — page-level configuration is now produced
        # inside ColumnChunkDecoder by PageHeaderParser. Offset 3 mirrors
        # page_header_parser_test.py (GlobalConfig occupies regs 0..2).
        for input in inputs:
            self.write_register(fpga_register.vFPGARegister(3, input._register()))

        # One stream input per column chunk (full thrift-wrapped bytes).
        for input in inputs:
            self.set_stream_input(0, input.chunk_bytes)

        # The output value width follows each chunk's declared type_t.
        for input, output in zip(inputs, outputs):
            self.set_expected_output(0, fpga_stream.Stream(input.stream_type, output))

        self.simulate_fpga()
        self.assert_simulation_output()

    def test_one_rle_page(self):
        self.run_chunks([_parquet_chunk('rle_data.parquet')], [_RLE_OUTPUT])

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
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
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
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
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

    
    # -- REQUIRED columns (no repetition/definition levels) -----------------
    #
    # A Parquet column with max_definition_level == 0 and
    # max_repetition_level == 0 writes no levels, so its page bodies have no
    # 4-byte level length prefix.
    
    def test_plain_page_without_levels(self):
        items = list(range(1, 11))
        self.run_chunks([make_plain_data(items, has_def_levels=False)], [items])

    def test_plain_page_without_levels_many_beats(self):
        self.run_chunks(
            [make_plain_data(_PLAIN_OUTPUT, has_def_levels=False)],
            [_PLAIN_OUTPUT],
        )

    def test_hybrid_page_without_levels(self):
        chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), [], 1,
            trailing_plain=False,
            has_def_levels=False,
        )
        self.run_chunks([chunk], [_RLE_OUTPUT])

    def test_plain_after_hybrid_without_levels(self):
        chunk = make_tricky(
            'rle_data_rg0_col0', len(_RLE_OUTPUT), _PLAIN_OUTPUT, 1,
            has_def_levels=False,
        )
        self.run_chunks([chunk], [_RLE_OUTPUT + _PLAIN_OUTPUT])

    def test_mixed_levels_across_chunks(self):
        items = list(range(1, 11))
        self.run_chunks(
            [
                _parquet_chunk('rle_data.parquet'),
                make_plain_data(items, has_def_levels=False),
                make_plain_data(_PLAIN_OUTPUT, has_def_levels=True),
            ],
            [_RLE_OUTPUT, items, _PLAIN_OUTPUT],
        )

