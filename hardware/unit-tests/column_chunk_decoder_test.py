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
from parcore_utils.fpga_configuration import (
    ColumnChunkDecoderConfig,
    Compression,
    GERMAN_STR_T,
)


INLINE_LEN = 12
DEFAULT_HEAP_ADDR = 0x1000


@dataclass
class _ColumnChunk:
    compression: bool
    num_values: int
    chunk_bytes: bytearray   # full column-chunk: thrift headers + payloads concatenated
    stream_type: "fpga_stream.StreamType" = fpga_stream.StreamType.SIGNED_INT_64
    is_required: bool = False  # REQUIRED columns have no definition levels in their data pages
    # Type the decoder casts the values to, None for stream_type (no cast)
    logical_type: Optional["fpga_stream.StreamType"] = None
    # BYTE_ARRAY columns have no fpga_stream.StreamType equivalent, so their
    # type_t is given directly.
    type_t_override: Optional[int] = None
    heap_addr: int = 0
    # String chunks only: the raw PLAIN bytes the decoder echoes on heap_out.
    expected_heap: Optional[bytearray] = None

    def output_type(self) -> "fpga_stream.StreamType":
        return self.logical_type if self.logical_type is not None else self.stream_type

    @property
    def data_type(self):
        return self.type_t_override if self.type_t_override is not None else self.stream_type

    @property
    def is_string(self) -> bool:
        return self.type_t_override == GERMAN_STR_T


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


# -- lineitem_stress_uniform.parquet, row group 0 ---------------------------
#
# vfpga_top hangs on column 3 of this file: input consumed, no write request ever
# issued, and 119k idle cycles after it. Columns 1 and 2 are the controls -- same
# chunk shape (one PLAIN dictionary page then four RLE_DICTIONARY data pages of 8
# values each) and they complete. The three differ only in how many dictionary
# entries they carry:
#
#   col1 l_partkey     32 entries, 256 B dictionary page   passes
#   col2 l_suppkey     11 entries,  88 B                   passes
#   col3 l_linenumber   7 entries,  56 B                   HANGS
#
# 7 entries is the first of the three that does not fill a whole DATABEAT_SIZE=32
# beat pair, which is why these run at both 32 and 64 bytes per beat.
#
# The chunks are inlined verbatim rather than read from the file: each is the
# byte range [dictionary_page_offset or data_page_offset, +total_compressed_size)
# of row group 0, i.e. thrift page headers plus their SNAPPY payloads, exactly
# what _extract_parquet_column_chunks used to hand over. All 48 row groups of
# lineitem_stress_uniform.parquet are byte-identical (it was generated with
# make_lineitem_stress.py --uniform), so row group 0 is the whole story.
_STRESS_ROWS = 32

# col0 l_orderkey  INT64  PLAIN, no dictionary  275 B
_STRESS_COL0_ORDERKEY = bytes.fromhex(
    # [  0] DATA PLAIN  nvals=8  header 18 B + payload 48 B
    "1500158c0115602c15101500150615060000461802000000"
    "1001000d0100040d0800080d08000c0d0800100d0800140d"
    "083c18000000000000001500000000000000"
    # [ 66] DATA PLAIN  nvals=8  header 18 B + payload 51 B
    "1500158c0115662c15101500150615060000461c02000000"
    "100119000901041d000901002109070400250d0800290d08"
    "002d0d083c2a000000000000002e00000000000000"
    # [135] DATA PLAIN  nvals=8  header 18 B + payload 52 B
    "1500158c0115682c15101500150615060000461c02000000"
    "1001320009010036090708003a000901003e09070400420d"
    "08003f0d083c43000000000000004700000000000000"
    # [205] DATA PLAIN  nvals=8  header 18 B + payload 52 B
    "1500158c0115682c15101500150615060000461c02000000"
    "10014b000901004f09070400530d08045700090100540907"
    "0400580d083c5c000000000000006000000000000000"
)

# col1 l_partkey  INT64  dictionary of 32 entries (-100..-69), 256 B body  282 B
_STRESS_COL1_PARTKEY = bytes.fromhex(
    # [  0] DICT PLAIN  nvals=32  header 16 B + payload 141 B
    "1504158004159a024c154015001200008002049cff090100"
    "9d090704ff9e0d08009f0d0800a00d0800a10d0800a20d08"
    "00a30d0800a40d0800a50d0800a60d0800a70d0800a80d08"
    "00a90d0800aa0d0800ab0d0800ac0d0800ad0d0800ae0d08"
    "00af0d0800b00d0800b10d0800b20d0800b30d0800b40d08"
    "00b50d0800b60d0800b70d0800b80d0800b90d083cbaffff"
    "ffffffffffbbffffffffffffff"
    # [157] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "01030388c6fa"
    # [187] DATA RLE_DICTIONARY  nvals=8  bit_width 4  header 17 B + payload 14 B
    "15001518151c2c151015101506150600000c2c0200000010"
    "01040398badcfe"
    # [218] DATA RLE_DICTIONARY  nvals=8  bit_width 5  header 17 B + payload 15 B
    "1500151a151e2c151015101506150600000d300200000010"
    "01050330ca49abbd"
    # [250] DATA RLE_DICTIONARY  nvals=8  bit_width 5  header 17 B + payload 15 B
    "1500151a151e2c151015101506150600000d300200000010"
    "01050338ebcdbbff"
)

# col2 l_suppkey  INT64  dictionary of 11 entries (-5..5), 88 B body  192 B
_STRESS_COL2_SUPPKEY = bytes.fromhex(
    # [  0] DICT PLAIN  nvals=11  header 15 B + payload 54 B
    "150415b001156c4c151615001200005804fbff090100fc09"
    "0704fffd0d0800fe0d08110100000d0100010d0800020d08"
    "00030d083c04000000000000000500000000000000"
    # [ 69] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "01030388c6fa"
    # [ 99] DATA RLE_DICTIONARY  nvals=8  bit_width 4  header 17 B + payload 14 B
    "15001518151c2c151015101506150600000c2c0200000010"
    "010403980a2143"
    # [130] DATA RLE_DICTIONARY  nvals=8  bit_width 4  header 17 B + payload 14 B
    "15001518151c2c151015101506150600000c2c0200000010"
    "0104036587a910"
    # [161] DATA RLE_DICTIONARY  nvals=8  bit_width 4  header 17 B + payload 14 B
    "15001518151c2c151015101506150600000c2c0200000010"
    "01040332547698"
)

# col3 l_linenumber  INT64  dictionary of 7 entries (1..7), 56 B body  174 B
_STRESS_COL3_LINENUMBER = bytes.fromhex(
    # [  0] DICT PLAIN  nvals=7  header 14 B + payload 40 B
    "1504157015504c150e150012000038040100090100020907"
    "0400030d0800040d0800050d083c06000000000000000700"
    "000000000000"
    # [ 54] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "01030388c61a"
    # [ 84] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "010303d15823"
    # [114] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "0103031a6b44"
    # [144] DATA RLE_DICTIONARY  nvals=8  bit_width 3  header 17 B + payload 13 B
    "15001516151a2c151015101506150600000b280200000010"
    "010303638d68"
)

_STRESS_CHUNKS = {
    0: _STRESS_COL0_ORDERKEY,
    1: _STRESS_COL1_PARTKEY,
    2: _STRESS_COL2_SUPPKEY,
    3: _STRESS_COL3_LINENUMBER,
}


def _stress_chunk(col: int) -> _ColumnChunk:
    return _ColumnChunk(
        compression=True,
        num_values=_STRESS_ROWS,
        chunk_bytes=bytearray(_STRESS_CHUNKS[col]),
    )


def stress_dict_chunks() -> list[tuple[str, int, list[int]]]:
    """(name, column index, expected values) for the three dictionary columns."""
    return [
        ('l_partkey',    1, [(i % 200) - 100 for i in range(_STRESS_ROWS)]),
        ('l_suppkey',    2, [(i % 11) - 5    for i in range(_STRESS_ROWS)]),
        ('l_linenumber', 3, [(i % 7) + 1     for i in range(_STRESS_ROWS)]),
    ]


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
    is_required: bool = False,
) -> _ColumnChunk:
    stream = fpga_stream.Stream(stream_type, items)
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
        stream_type=stream_type,
        is_required=is_required,
    )


# -- Synthetic PLAIN BYTE_ARRAY (german string) chunk ------------------------

def _encode_strings(strings: list[bytes]) -> bytearray:
    """PLAIN BYTE_ARRAY encoding: 4-byte LE length prefix followed by payload."""
    buf = bytearray()
    for s in strings:
        buf += len(s).to_bytes(4, 'little')
        buf += s
    return buf


def _heap_bytes(strings: list[bytes]) -> bytearray:
    """The heap the decoder writes: the payloads of the strings that do not fit
    inline, back to back and without their length prefixes."""
    return bytearray(b''.join(s for s in strings if len(s) > INLINE_LEN))


def _german_records(strings: list[bytes], heap_addr: int) -> list[int]:
    """The german_str_t records the decoder emits, serialised LSB-first.

    Each 16-byte record is length[0:4] | prefix[4:8] | payload[8:16], where the
    payload is the inline bytes 4..11 for strings of at most INLINE_LEN bytes and
    an 8-byte heap address otherwise. Only the strings that do not fit inline are
    in the heap (see _heap_bytes), so a string's address is heap_addr plus the
    length of the long strings before it.
    """
    out = bytearray()
    heap_offset = 0
    for s in strings:
        n = len(s)
        rec = bytearray(16)
        rec[0:4] = n.to_bytes(4, 'little')
        rec[4:8] = s[:4].ljust(4, b'\x00')
        if n <= INLINE_LEN:
            rec[8:16] = s[4:12].ljust(8, b'\x00')
        else:
            rec[8:16] = (heap_addr + heap_offset).to_bytes(8, 'little')
            heap_offset += n
        out += rec
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
        expected_heap=_heap_bytes(strings),
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
                0, compression, input.num_values, input.data_type, input.is_required,
                input.logical_type if not input.is_string else None, input.heap_addr
            )

        # One stream input per column chunk (full thrift-wrapped bytes).
        for input in self.inputs:
            self.set_stream_input(0, input.chunk_bytes)

        # The output value width follows each chunk's logical type. String chunks emit fixed
        # 16-byte german_str_t records, so they are compared as raw bytes.
        for input, output in zip(self.inputs, self.outputs):
            if input.is_string:
                self.set_expected_output(
                    0, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_8, output))
            else:
                self.set_expected_output(0, fpga_stream.Stream(input.output_type(), output))

        # heap_out carries the raw string bytes for long strings; it stays idle for fixed-width
        # chunks.
        for input in self.inputs:
            if input.expected_heap is not None:
                self.set_expected_output(
                    1, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_8,
                                          list(input.expected_heap)))

    def finish_input(self, end_event):
        # Reads the profile once all outputs were written, while the simulation is still running.
        if self.read_profile_after_run:
            self.get_io_writer().block_till_completed(
                io_writer.CoyoteOperator.LOCAL_WRITE,
                self._expected_completed_write_transfers,
                end_event,
            )
            self.profile = self.config.get_config(ColumnChunkDecoderConfig).read_profile(0)

        # Not super(): ColumnChunkDecoder32TestCase reuses this method without subclassing
        ConfiguredTestCase.finish_input(self, end_event)

    def run_chunks(self, inputs: list[_ColumnChunk], outputs: list[list[int]],
                   read_profile: bool = False):
        """Drive the decoder with one or more column chunks and assert outputs."""
        self.inputs = inputs
        self.outputs = outputs
        self.read_profile_after_run = read_profile

        self.simulate_fpga()
        self.assert_simulation_output()

    def _run_stress_column(self, col: int, expected: list[int]):
        self.run_chunks([_stress_chunk(col)], [expected])

    def test_stress_dict_32_entries(self):
        """Control: 32-entry dictionary, 4 pages of 8 values."""
        self._run_stress_column(*stress_dict_chunks()[0][1:])

    def test_stress_dict_11_entries(self):
        """Control: 11-entry dictionary."""
        self._run_stress_column(*stress_dict_chunks()[1][1:])

    def test_stress_dict_7_entries(self):
        """l_linenumber: 7-entry dictionary. Hangs vfpga_top at DATABEAT_SIZE=32."""
        self._run_stress_column(*stress_dict_chunks()[2][1:])

    def _run_stress_sequence(self, cols: list[int], expected: list[list[int]]):
        self.run_chunks([_stress_chunk(c) for c in cols], expected)

    def test_stress_dict_two_back_to_back(self):
        cases = stress_dict_chunks()[:2]
        self._run_stress_sequence([c for _, c, _ in cases], [e for _, _, e in cases])

    def test_stress_dict_all_three_back_to_back(self):
        """The failing chunk preceded by the two that work, as vfpga_top saw it."""
        cases = stress_dict_chunks()
        self._run_stress_sequence([c for _, c, _ in cases], [e for _, _, e in cases])

    def test_stress_dict_same_chunk_three_times(self):
        """Separates "third dictionary chunk" from "a dictionary that shrank"."""
        _, col, expected = stress_dict_chunks()[2]
        self._run_stress_sequence([col] * 3, [expected] * 3)

    def test_stress_dict_shrinking_dictionaries(self):
        """32 -> 11 -> 7 entries, the order vfpga_top hit. Reversed below."""
        cases = stress_dict_chunks()
        self._run_stress_sequence([c for _, c, _ in cases], [e for _, _, e in cases])

    def test_stress_dict_growing_dictionaries(self):
        """7 -> 11 -> 32 entries."""
        cases = list(reversed(stress_dict_chunks()))
        self._run_stress_sequence([c for _, c, _ in cases], [e for _, _, e in cases])

    def test_stress_plain_then_dicts(self):
        """l_orderkey (PLAIN) first, exactly as vfpga_top decoded row group 0."""
        cases = stress_dict_chunks()
        self._run_stress_sequence(
            [0] + [c for _, c, _ in cases],
            [[i * 3 + (i % 7) for i in range(_STRESS_ROWS)]] + [e for _, _, e in cases])

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
        strings = [b'alpha', b'b' * 30, b'gamma']
        self.run_chunks(
            [make_string_data(strings), make_plain_data(_PLAIN_OUTPUT)],
            [_german_records(strings, DEFAULT_HEAP_ADDR), _PLAIN_OUTPUT],
        )

    def test_fixed_then_string(self):
        strings = [b'x' * 18, b'yz']
        self.run_chunks(
            [make_plain_data(_PLAIN_OUTPUT), make_string_data(strings)],
            [_PLAIN_OUTPUT, _german_records(strings, DEFAULT_HEAP_ADDR)],
        )

    def test_back_to_back_string_chunks(self):
        # Two string chunks in a row: the second must pick up its own heap base,
        # which only happens if psd_first_page re-arms on the chunk boundary.
        first = [b'a' * 20, b'bb']
        second = [b'c' * 15, b'dddd', b'e' * 40]
        self.run_chunks(
            [make_string_data(first, 0x1000), make_string_data(second, 0x9000)],
            [_german_records(first, 0x1000), _german_records(second, 0x9000)],
        )

    def test_string_between_hybrid_chunks(self):
        # A string chunk sandwiched between dictionary-encoded chunks, exercising
        # the dictionary flush and the string path in the same run.
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
