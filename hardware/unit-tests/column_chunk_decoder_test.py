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


GERMAN_STR_T = 5

INLINE_LEN = 12
DEFAULT_HEAP_ADDR = 0x1000


@dataclass
class _ColumnChunk:
    compression: bool
    num_values: int
    chunk_bytes: bytearray   # full column-chunk: thrift headers + payloads concatenated
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64
    # BYTE_ARRAY columns have no fpga_stream.StreamType equivalent, so their
    # type_t is given directly.
    type_t_override: int | None = None
    heap_addr: int = 0
    # String chunks only: the raw PLAIN bytes the decoder echoes on heap_out.
    expected_heap: bytearray | None = None

    @property
    def type_t(self) -> int:
        if self.type_t_override is not None:
            return self.type_t_override
        return stream_type_to_libstf_type_t(self.stream_type)

    @property
    def is_string(self) -> bool:
        return self.type_t == GERMAN_STR_T

    def _register(self) -> bytearray:
        # column_chunk_conf_t packs (MSB -> LSB) as:
        #   compression_t [1 bit] | num_values [32 bits] | type_t [3 bits]
        compression = 1 if self.compression else 0
        packed = (compression << 35) | ((self.num_values & 0xFFFFFFFF) << 3) | (self.type_t & 0x7)
        return bytearray(packed.to_bytes(8, 'little'))

    def _heap_register(self) -> bytearray:
        return bytearray(self.heap_addr.to_bytes(8, 'little'))


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


def make_plain_data(
    items: list,
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64,
) -> _ColumnChunk:
    stream = fpga_stream.Stream(stream_type, items)
    values = stream.data_to_bytearray()
    def_levels = _make_def_levels(len(items))
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
        stream_type=stream_type,
    )


# -- Synthetic PLAIN BYTE_ARRAY (german string) chunk ------------------------

def _encode_strings(strings: list[bytes]) -> bytearray:
    """PLAIN BYTE_ARRAY encoding: 4-byte LE length prefix followed by payload."""
    buf = bytearray()
    for s in strings:
        buf += len(s).to_bytes(4, 'little')
        buf += s
    return buf


def _german_records(strings: list[bytes], heap_addr: int) -> list[int]:
    """The german_str_t records the decoder emits, serialised LSB-first.

    Each 16-byte record is length[0:4] | prefix[4:8] | payload[8:16], where the
    payload is the inline bytes 4..11 for strings of at most INLINE_LEN bytes and
    an 8-byte heap address otherwise. The heap mirrors the encoded page verbatim,
    length prefixes included, so a string's address is its payload offset within
    that stream. Mirrors _expected_strings in plain_string_decoder_test.py.
    """
    out = bytearray()
    element_offset = 4  # the first payload sits after its own length prefix
    for s in strings:
        n = len(s)
        rec = bytearray(16)
        rec[0:4] = n.to_bytes(4, 'little')
        rec[4:8] = s[:4].ljust(4, b'\x00')
        if n <= INLINE_LEN:
            rec[8:16] = s[4:12].ljust(8, b'\x00')
        else:
            rec[8:16] = (heap_addr + element_offset).to_bytes(8, 'little')
        out += rec
        element_offset += n + 4
    return list(out)


def make_string_data(
    strings: list[bytes],
    heap_addr: int = DEFAULT_HEAP_ADDR,
) -> _ColumnChunk:
    values = _encode_strings(strings)
    def_levels = _make_def_levels(len(strings))
    payload = bytearray(def_levels) + values
    hdr = _make_data_page_header(
        num_values=len(strings),
        uncompressed_size=len(payload),
        compressed_size=len(payload),
        encoding=0,  # PLAIN
    )
    return _ColumnChunk(
        compression=False,
        num_values=len(strings),
        chunk_bytes=bytearray(hdr) + payload,
        type_t_override=GERMAN_STR_T,
        heap_addr=heap_addr,
        expected_heap=values,
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
) -> _ColumnChunk:
    hybrid_body = read_bytes(filename + '_chunk_decompressed.bin')

    chunk = bytearray()

    # Dictionary page: encoding=PLAIN, values at the column's width.
    dict_body = bytearray(fpga_stream.Stream(stream_type, dict_values).data_to_bytearray())
    chunk += _make_dict_page_header(
        num_values=len(dict_values),
        uncompressed_size=len(dict_body),
        compressed_size=len(dict_body),
    )
    chunk += dict_body

    # `factor` HYBRID pages. Each body already carries its 4-byte def_levels
    # length prefix + def_levels + RLE/BPE-encoded payload — PageHeaderParser's
    # SKIP_DEF_LEVELS state will strip the def_levels prefix at runtime.
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
        plain_def_levels = _make_def_levels(len(items))
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
            # The heap base lives in a second register that ColumnChunkDecoderConfig
            # only consumes for german string chunks, so it is written only for
            # those - writing it otherwise would desynchronise the two FIFOs.
            if input.is_string:
                self.write_register(fpga_register.vFPGARegister(4, input._heap_register()))

        # One stream input per column chunk (full thrift-wrapped bytes).
        for input in inputs:
            self.set_stream_input(0, input.chunk_bytes)

        # The output value width follows each chunk's declared type_t. String
        # chunks emit fixed 16-byte german_str_t records, so they are compared as
        # raw bytes rather than through a typed stream.
        for input, output in zip(inputs, outputs):
            if input.is_string:
                self.set_expected_output(
                    0, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_8, output))
            else:
                self.set_expected_output(0, fpga_stream.Stream(input.stream_type, output))

        # heap_out carries the raw string bytes for long strings; it stays idle
        # for fixed-width chunks.
        for input in inputs:
            if input.expected_heap is not None:
                self.set_expected_output(
                    1, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_8,
                                          list(input.expected_heap)))

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

    # -- German strings -----------------------------------------------------
    #
    # A PLAIN BYTE_ARRAY chunk takes the string path: StripLevels -> PlainRouter
    # -> StringRouter -> PlainStringDecoder -> GermanStrToNData -> out. Values
    # land on stream 0 as 16-byte german_str_t records and the raw bytes are
    # echoed on heap_out (stream 1).

    def _run_strings(self, strings: list[bytes], heap_addr: int = DEFAULT_HEAP_ADDR):
        chunk = make_string_data(strings, heap_addr)
        self.run_chunks([chunk], [_german_records(strings, heap_addr)])

    def test_string_single_short(self):
        self._run_strings([b'abc'])

    def test_string_all_inline(self):
        # Every string fits in the 12 inline bytes, so no heap address is used.
        self._run_strings([b'a', b'bb', b'ccc', b'abcdefghijkl'])

    def test_string_inline_boundary(self):
        # 12 bytes is the last inline length; 13 is the first that spills.
        self._run_strings([b'a' * INLINE_LEN, b'b' * (INLINE_LEN + 1)])

    def test_string_all_long(self):
        # Every record stores a heap address rather than inline bytes.
        self._run_strings([b'x' * 20, b'y' * 33, b'z' * 17])

    def test_string_mixed_lengths(self):
        self._run_strings([b'ab', b'c' * 40, b'defghijkl', b'm' * 13, b'', b'no'])

    def test_string_multi_beat(self):
        # More than four records per 64-byte beat, forcing GermanStrToNData to
        # emit several full beats plus a partial final one.
        strings = [bytes([0x41 + (i % 26)]) * (1 + i % 30) for i in range(37)]
        self._run_strings(strings)

    def test_string_nondefault_heap_addr(self):
        self._run_strings([b'p' * 25, b'q' * 14], heap_addr=0xDEAD0000)

    # -- Mixed data types ---------------------------------------------------

    def test_mixed_fixed_widths(self):
        # One chunk per fixed width, back to back. Each chunk reconfigures the
        # byte scaling that NormalizeUntil and DataRewriteLast are driven with,
        # so a wrong shift shows up as a truncated or never-terminating output.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        bytes_out = list(range(0, 200))
        i32 = list(range(-100, 100))
        i64 = list(range(0, 150))
        self.run_chunks(
            [
                make_plain_data(bytes_out, fpga_stream.StreamType.UNSIGNED_INT_8),
                make_plain_data(i32, fpga_stream.StreamType.SIGNED_INT_32),
                make_plain_data(i64, fpga_stream.StreamType.SIGNED_INT_64),
            ],
            [bytes_out, i32, i64],
        )

    def test_mixed_float_widths(self):
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        f32 = [float(i) for i in range(0, 128)]
        f64 = [float(i) * 0.5 for i in range(0, 96)]
        self.run_chunks(
            [
                make_plain_data(f32, fpga_stream.StreamType.FLOAT_32),
                make_plain_data(f64, fpga_stream.StreamType.FLOAT_64),
            ],
            [f32, f64],
        )

    def test_string_then_fixed(self):
        # The type switch that matters most: the string path must fully drain and
        # the PSD's first-page latch must re-arm before the fixed chunk runs.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        strings = [b'alpha', b'b' * 30, b'gamma']
        self.run_chunks(
            [make_string_data(strings), make_plain_data(_PLAIN_OUTPUT)],
            [_german_records(strings, DEFAULT_HEAP_ADDR), _PLAIN_OUTPUT],
        )

    def test_fixed_then_string(self):
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        strings = [b'x' * 18, b'yz']
        self.run_chunks(
            [make_plain_data(_PLAIN_OUTPUT), make_string_data(strings)],
            [_PLAIN_OUTPUT, _german_records(strings, DEFAULT_HEAP_ADDR)],
        )

    def test_back_to_back_string_chunks(self):
        # Two string chunks in a row: the second must pick up its own heap base,
        # which only happens if psd_first_page re-arms on the chunk boundary.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        first = [b'a' * 20, b'bb']
        second = [b'c' * 15, b'dddd', b'e' * 40]
        self.run_chunks(
            [make_string_data(first, 0x1000), make_string_data(second, 0x9000)],
            [_german_records(first, 0x1000), _german_records(second, 0x9000)],
        )

    def test_string_between_hybrid_chunks(self):
        # A string chunk sandwiched between dictionary-encoded chunks, exercising
        # the dictionary flush and the string path in the same run.
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        strings = [b'mid', b'f' * 22]
        self.run_chunks(
            [
                _parquet_chunk('rle_data.parquet'),
                make_string_data(strings),
                _parquet_chunk('bpe_data.parquet'),
            ],
            [
                _RLE_OUTPUT,
                _german_records(strings, DEFAULT_HEAP_ADDR),
                list(range(10, 20)) * 15,
            ],
        )
