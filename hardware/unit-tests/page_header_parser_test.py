import os
from dataclasses import dataclass
from enum import IntEnum
from coyote_test import fpga_test_case, fpga_register, simulation_time

import pyarrow.parquet as pq


class _PageType(IntEnum):
    HYBRID = 0
    DICT   = 1
    PLAIN  = 2


@dataclass
class _ExpectedPage:
    page_type:  _PageType
    num_values: int
    last:       bool
    payload:    bytearray   # raw compressed payload bytes (header stripped)


@dataclass
class _TestCase:
    chunk_num_values: int
    chunk_bytes:      bytearray         # raw column-chunk bytes (headers + payloads)
    pages:            list[_ExpectedPage]


# ---------------------------------------------------------------------------
# Thrift compact-protocol header builders
# ---------------------------------------------------------------------------

def _zigzag_encode(n: int) -> int:
    return (n << 1) ^ (n >> 31)

def _encode_varint(n: int) -> bytearray:
    n = _zigzag_encode(n)
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            break
    return out

def _make_data_page_header(
    num_values: int,
    uncompressed_size: int,
    compressed_size: int,
    encoding: int,
) -> bytearray:
    """Minimal Thrift compact DataPageHeader (no CRC, no statistics)."""
    h = bytearray()
    h += b'\x15' + _encode_varint(0)               # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)
    h += b'\x15' + _encode_varint(compressed_size)
    h += b'\x2c'                                    # fid5: data_page_header STRUCT
    h += b'\x15' + _encode_varint(num_values)       # inner fid1
    h += b'\x15' + _encode_varint(encoding)         # inner fid2: encoding
    h += b'\x15' + _encode_varint(0)                # inner fid3: def_level_enc=PLAIN
    h += b'\x15' + _encode_varint(0)                # inner fid4: rep_level_enc=PLAIN
    h += b'\x00'                                    # inner STOP
    h += b'\x00'                                    # outer STOP
    return h

def _encode_binary(data: bytes) -> bytearray:
    """Thrift compact binary field value: length (unsigned varint) + bytes."""
    out = bytearray()
    n = len(data)
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            break
    out += data
    return out

def _make_data_page_header_full(
    num_values: int,
    uncompressed_size: int,
    compressed_size: int,
    encoding: int,
    def_level_encoding: int,
    rep_level_encoding: int,
    crc: int,
    stats_max: bytes,
    stats_min: bytes,
    stats_null_count: int,
    stats_distinct_count: int,
    stats_max_value: bytes,
    stats_min_value: bytes,
    stats_is_max_exact: bool,
    stats_is_min_exact: bool,
) -> bytearray:
    """Thrift compact DataPageHeader with all optional fields including full Statistics."""
    # Build Statistics struct body (all 8 fields, each with delta_fid=1)
    stats = bytearray()
    stats += b'\x18' + _encode_binary(stats_max)           # fid1: max (binary)
    stats += b'\x18' + _encode_binary(stats_min)           # fid2: min (binary)
    stats += b'\x15' + _encode_varint(stats_null_count)    # fid3: null_count (i64)
    stats += b'\x15' + _encode_varint(stats_distinct_count)# fid4: distinct_count (i64)
    stats += b'\x18' + _encode_binary(stats_max_value)     # fid5: max_value (binary)
    stats += b'\x18' + _encode_binary(stats_min_value)     # fid6: min_value (binary)
    stats += bytes([0x11 if stats_is_max_exact else 0x12]) # fid7: is_max_value_exact (bool)
    stats += bytes([0x11 if stats_is_min_exact else 0x12]) # fid8: is_min_value_exact (bool)
    stats += b'\x00'                                        # STOP

    h = bytearray()
    h += b'\x15' + _encode_varint(0)                  # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)  # fid2: uncompressed_page_size
    h += b'\x15' + _encode_varint(compressed_size)    # fid3: compressed_page_size
    h += b'\x15' + _encode_varint(crc)                # fid4: crc (optional i32)
    h += b'\x1c'                                       # fid5: data_page_header STRUCT (delta=1)
    h += b'\x15' + _encode_varint(num_values)          # inner fid1: num_values
    h += b'\x15' + _encode_varint(encoding)            # inner fid2: encoding
    h += b'\x15' + _encode_varint(def_level_encoding)  # inner fid3: definition_level_encoding
    h += b'\x15' + _encode_varint(rep_level_encoding)  # inner fid4: repetition_level_encoding
    h += b'\x1c'                                       # inner fid5: statistics STRUCT (delta=1)
    h += stats
    h += b'\x00'                                       # inner STOP (DataPageHeader)
    h += b'\x00'                                       # outer STOP (PageHeader)
    return h


def _make_data_page_header_sparse_stats(
    num_values: int,
    uncompressed_size: int,
    compressed_size: int,
    encoding: int,
    def_level_encoding: int,
    rep_level_encoding: int,
    crc: int,
    stats_max: bytes,
    stats_max_value: bytes,
    stats_is_min_exact: bool,
) -> bytearray:
    """DataPageHeader where Statistics writes only fids 1, 5, 8 (deltas 1, 4, 3).

    Forces tag bytes 0x48 and 0x31, exercising high-nibble (delta>1) dispatch.
    """
    stats = bytearray()
    stats += b'\x18' + _encode_binary(stats_max)           # fid1: max (binary), delta 1
    stats += b'\x48' + _encode_binary(stats_max_value)     # fid5: max_value (binary), delta 4
    stats += bytes([0x31 if stats_is_min_exact else 0x32]) # fid8: is_min_value_exact (bool), delta 3
    stats += b'\x00'                                        # STOP

    h = bytearray()
    h += b'\x15' + _encode_varint(0)                  # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)  # fid2: uncompressed_page_size
    h += b'\x15' + _encode_varint(compressed_size)    # fid3: compressed_page_size
    h += b'\x15' + _encode_varint(crc)                # fid4: crc (optional i32)
    h += b'\x1c'                                       # fid5: data_page_header STRUCT (delta=1)
    h += b'\x15' + _encode_varint(num_values)          # inner fid1: num_values
    h += b'\x15' + _encode_varint(encoding)            # inner fid2: encoding
    h += b'\x15' + _encode_varint(def_level_encoding)  # inner fid3: definition_level_encoding
    h += b'\x15' + _encode_varint(rep_level_encoding)  # inner fid4: repetition_level_encoding
    h += b'\x1c'                                       # inner fid5: statistics STRUCT (delta=1)
    h += stats
    h += b'\x00'                                       # inner STOP (DataPageHeader)
    h += b'\x00'                                       # outer STOP (PageHeader)
    return h


def _encode_uleb128(n: int) -> bytearray:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            b |= 0x80
        out.append(b)
        if not n:
            break
    return out

def _encode_i64(n: int) -> bytearray:
    """Thrift compact i64 field value: 64-bit zigzag + ULEB128."""
    return _encode_uleb128((n << 1) ^ (n >> 63))

def _make_data_page_header_i64_stats(
    num_values: int,
    uncompressed_size: int,
    compressed_size: int,
    encoding: int,
    stats_max: bytes,
    stats_min: bytes,
    stats_null_count: int,
    stats_distinct_count: int,
    stats_max_value: bytes,
    stats_min_value: bytes,
) -> bytearray:
    """DataPageHeader with Statistics as written by parquet-cpp (e.g. ClickBench hits.parquet).

    null_count and distinct_count are Thrift i64 fields, so their tag bytes carry compact type 6
    (0x16) rather than the i32 type 5 (0x15) used everywhere else in the page header.
    """
    stats = bytearray()
    stats += b'\x18' + _encode_binary(stats_max)           # fid1: max (binary)
    stats += b'\x18' + _encode_binary(stats_min)           # fid2: min (binary)
    stats += b'\x16' + _encode_i64(stats_null_count)       # fid3: null_count (i64)
    stats += b'\x16' + _encode_i64(stats_distinct_count)   # fid4: distinct_count (i64)
    stats += b'\x18' + _encode_binary(stats_max_value)     # fid5: max_value (binary)
    stats += b'\x18' + _encode_binary(stats_min_value)     # fid6: min_value (binary)
    stats += b'\x00'                                        # STOP

    h = bytearray()
    h += b'\x15' + _encode_varint(0)                  # fid1: page_type=DATA_PAGE(0)
    h += b'\x15' + _encode_varint(uncompressed_size)  # fid2: uncompressed_page_size
    h += b'\x15' + _encode_varint(compressed_size)    # fid3: compressed_page_size
    h += b'\x2c'                                       # fid5: data_page_header STRUCT (delta=2)
    h += b'\x15' + _encode_varint(num_values)          # inner fid1: num_values
    h += b'\x15' + _encode_varint(encoding)            # inner fid2: encoding
    h += b'\x15' + _encode_varint(3)                   # inner fid3: definition_level_encoding=RLE
    h += b'\x15' + _encode_varint(3)                   # inner fid4: repetition_level_encoding=RLE
    h += b'\x1c'                                       # inner fid5: statistics STRUCT (delta=1)
    h += stats
    h += b'\x00'                                       # inner STOP (DataPageHeader)
    h += b'\x00'                                       # outer STOP (PageHeader)
    return h


def _make_dict_page_header(
    num_values: int,
    uncompressed_size: int,
    compressed_size: int,
) -> bytearray:
    """Minimal Thrift compact DictionaryPageHeader."""
    h = bytearray()
    h += b'\x15' + _encode_varint(2)               # fid1: page_type=DICTIONARY_PAGE(2)
    h += b'\x15' + _encode_varint(uncompressed_size)
    h += b'\x15' + _encode_varint(compressed_size)
    h += b'\x4c'                                    # fid7: dictionary_page_header STRUCT
    h += b'\x15' + _encode_varint(num_values)       # inner fid1
    h += b'\x15' + _encode_varint(0)                # inner fid2: encoding=PLAIN
    h += b'\x00'                                    # inner STOP
    h += b'\x00'                                    # outer STOP
    return h

def _hw_page_type(thrift_page_type: int, encoding: int) -> _PageType:
    if thrift_page_type == 2:
        return _PageType.DICT
    elif encoding == 0:
        return _PageType.PLAIN
    else:
        return _PageType.HYBRID


# ---------------------------------------------------------------------------
# Build test cases from synthetic headers
# ---------------------------------------------------------------------------

def _make_synthetic_plain(num_values: int, payload_size: int, last: bool) -> tuple[bytearray, _ExpectedPage]:
    payload = bytearray(range(payload_size % 256)) * (payload_size // 256 + 1)
    payload = payload[:payload_size]
    hdr = _make_data_page_header(num_values, payload_size, payload_size, 0)
    chunk = hdr + payload
    page = _ExpectedPage(
        page_type=_PageType.PLAIN,
        num_values=num_values,
        last=last,
        payload=bytearray(payload),
    )
    return chunk, page

def _make_synthetic_hybrid(num_values: int, payload_size: int, last: bool) -> tuple[bytearray, _ExpectedPage]:
    # Hybrid page payload layout: 4-byte def_levels length (LE) | def_levels bytes | encoded data.
    # The hardware passes the full compressed body through unchanged.
    def_levels_len = 8
    def_levels = bytearray(b'\x55' * def_levels_len)
    encoded = bytearray(b'\xab' * payload_size)
    body = bytearray(def_levels_len.to_bytes(4, 'little')) + def_levels + encoded
    hdr = _make_data_page_header(num_values, len(body), len(body), 8)  # RLE_DICT=8
    chunk = hdr + body
    page = _ExpectedPage(
        page_type=_PageType.HYBRID,
        num_values=num_values,
        last=last,
        payload=bytearray(body),
    )
    return chunk, page

def _make_synthetic_dict(num_values: int, payload_size: int) -> tuple[bytearray, _ExpectedPage]:
    payload = bytearray(b'\xcd' * payload_size)
    hdr = _make_dict_page_header(num_values, payload_size, payload_size)
    chunk = hdr + payload
    page = _ExpectedPage(
        page_type=_PageType.DICT,
        num_values=num_values,
        last=False,
        payload=bytearray(payload),
    )
    return chunk, page


# Real PLAIN dictionary payload from column chunk 5 of l_discount (TPC-H SF1
# lineitem, col 6). It is exactly 50 bytes, which together with the 14-byte
# dictionary page header lands the *following* data-page header on a 64-byte
# AXI-beat boundary — the alignment that triggers the header misparse below.
_L_DISCOUNT_CC5_DICT_PAYLOAD = bytes.fromhex(
    '580406000901000709070400050d0800010d0800020d0800090d0800030d'
    '0800040d08000a0d0811011c0800000000000000'
)

def _page_boundary_aligned_case() -> _TestCase:
    """Synthetic repro of the l_discount header misparse (drain lock-up root cause).

    Uses the real dictionary payload from column chunk 5 of l_discount. That
    payload is 50 bytes; with the 14-byte dictionary page header the dict page is
    exactly 64 bytes, so it ends *on* a 64-byte AXI-beat boundary (NUM_BYTES=64)
    and the following data-page header starts at byte 0 of the next beat.

    In that alignment the parser used to misread the data page's num_values
    varint: the first header byte (0x15, the page_type tag) was consumed as the
    num_values varint (15 -> zigzag -8 -> 0xFFFFFFF8) instead of decoding the real
    num_values (122880). Downstream that bogus count wedges the RunDecoder and
    deadlocks the pipeline; here it surfaces directly as a wrong page_conf
    num_values / mis-sized payload passthrough.

    The data page is a RLE_DICT (hybrid) page. Its payload size is chosen so the
    data page also ends cleanly; only the header alignment matters for the bug.
    """
    dict_payload = bytearray(_L_DISCOUNT_CC5_DICT_PAYLOAD)
    dict_ps      = len(dict_payload)            # 50 (compressed)
    dict_us      = 88                           # uncompressed: real value, a 2-byte
                                                # varint that makes the header 14 bytes
    dict_nv      = 11
    dict_hdr     = _make_dict_page_header(dict_nv, dict_us, dict_ps)
    assert len(dict_hdr) == 14, len(dict_hdr)
    assert len(dict_hdr) + dict_ps == 64, "dict page must end on a 64-byte beat boundary"
    dict_page = _ExpectedPage(
        page_type  = _PageType.DICT,
        num_values = dict_nv,
        last       = False,
        payload    = bytearray(dict_payload),
    )

    data_nv, data_ps = 122880, 96
    data_chunk, data_page = _make_synthetic_hybrid(data_nv, data_ps, last=True)

    chunk = bytearray(dict_hdr) + dict_payload + bytearray(data_chunk)
    return _TestCase(
        chunk_num_values = data_nv,
        chunk_bytes      = chunk,
        pages            = [dict_page, data_page],
    )


def _single_plain_page_case() -> _TestCase:
    num_values = 20
    payload_size = 64
    chunk, page = _make_synthetic_plain(num_values, payload_size, last=True)
    page.last = True
    return _TestCase(
        chunk_num_values=num_values,
        chunk_bytes=bytearray(chunk),
        pages=[page],
    )

def _single_hybrid_page_case() -> _TestCase:
    num_values = 100
    payload_size = 128
    chunk, page = _make_synthetic_hybrid(num_values, payload_size, last=True)
    return _TestCase(
        chunk_num_values=num_values,
        chunk_bytes=bytearray(chunk),
        pages=[page],
    )

def _dict_plus_hybrid_case() -> _TestCase:
    """Dict page followed by a hybrid data page.

    Payload sizes are chosen to exercise two specific paths (NUM_BYTES = 64):

    1. PAYLOAD_DRAIN_BUF Case A for the dict page:
       The dict header is ~13 bytes. After LATCH_FIRST strips the fid1 tag,
       ~51 bytes of the first AXI beat remain in the buffer, which is more
       than dict_ps=20. So remaining_bytes(~51) > remaining_comp_size(20) and
       Case A fires: skip_bytes is set to 20+1=21 and the FSM jumps directly
       to PARSE_TYPE for the data page header.

    2. PAYLOAD_BYPASS final-beat path (RTL line 349) with skip_bytes != 0 at
       entry (the TODO on line 339): after Case A sets skip_bytes=21 the
       parser consumes the data page header with the skip counter running down.
       By the time PAYLOAD_BYPASS is entered skip_bytes is 0, so the
       `n_skip_bytes = '0` assignment on line 367 is a no-op — but the branch
       itself is reached because data_ps=100 leaves a 36-byte final beat
       (remaining_comp_size=36 < NUM_BYTES=64).
    """
    dict_nv, dict_ps = 8, 20
    data_nv, data_ps = 50, 100
    dict_chunk, dict_page = _make_synthetic_dict(dict_nv, dict_ps)
    data_chunk, data_page = _make_synthetic_hybrid(data_nv, data_ps, last=True)
    data_page.last = True
    chunk = bytearray(dict_chunk) + bytearray(data_chunk)
    return _TestCase(
        chunk_num_values=data_nv,
        chunk_bytes=chunk,
        pages=[dict_page, data_page],
    )

def _large_plain_case() -> _TestCase:
    """Payload spanning multiple 64-byte AXI beats."""
    num_values = 1000
    payload_size = 8000
    chunk, page = _make_synthetic_plain(num_values, payload_size, last=True)
    return _TestCase(
        chunk_num_values=num_values,
        chunk_bytes=bytearray(chunk),
        pages=[page],
    )

def _data_page_all_optional_fields_case() -> _TestCase:
    """DataPageHeader with CRC and all 8 Statistics fields populated.

    The header is 73 bytes and spans two 64-byte AXI beats.
    """
    num_values   = 42
    payload_size = 80
    encoding     = 0  # PLAIN

    payload = bytearray(range(payload_size % 256)) * (payload_size // 256 + 1)
    payload = payload[:payload_size]

    hdr = _make_data_page_header_full(
        num_values           = num_values,
        uncompressed_size    = payload_size,
        compressed_size      = payload_size,
        encoding             = encoding,
        def_level_encoding   = 0,   # PLAIN
        rep_level_encoding   = 0,   # PLAIN
        crc                  = 0x12345678,
        stats_max            = b'\xff\xff\xff\xff\xff\xff\xff\x7f',  # INT64 max
        stats_min            = b'\x00\x00\x00\x00\x00\x00\x00\x80',  # INT64 min
        stats_null_count     = 3,
        stats_distinct_count = 39,
        stats_max_value      = b'\xff\xff\xff\xff\xff\xff\xff\x7f',
        stats_min_value      = b'\x00\x00\x00\x00\x00\x00\x00\x80',
        stats_is_max_exact   = True,
        stats_is_min_exact   = True,
    )
    chunk = hdr + payload
    page = _ExpectedPage(
        page_type  = _PageType.PLAIN,
        num_values = num_values,
        last       = True,
        payload    = bytearray(payload),
    )
    return _TestCase(
        chunk_num_values = num_values,
        chunk_bytes      = bytearray(chunk),
        pages            = [page],
    )


def _deep_header_small_payload_case() -> _TestCase:
    """Synthetic page whose header is long enough that the final buffer refill
    in IS_END leaves remaining_bytes > NUM_BYTES when PAYLOAD_DRAIN_BUF is
    entered.  This exercises the TODO path on line 311 of page_header_parser.sv
    where the buffer holds more than one full AXI beat of payload residue.

    We achieve a long header by including CRC + full Statistics with two binary
    fields (8 bytes each), which pushes the header past two 64-byte AXI beats.
    The payload is kept small (3 bytes) so it fits entirely inside the residue
    that was already loaded during header parsing.
    """
    num_values   = 5
    payload_size = 73
    encoding     = 0  # PLAIN

    payload = bytearray(b'\xDE\xAD\xBE' + bytes(range(70)))

    hdr = _make_data_page_header_full(
        num_values           = num_values,
        uncompressed_size    = payload_size,
        compressed_size      = payload_size,
        encoding             = encoding,
        def_level_encoding   = 0,
        rep_level_encoding   = 0,
        crc                  = 0x00FEBABE,
        stats_max            = b'\xff\xff\xff\xff\xff\xff',
        stats_min            = b'\x00\x00\x00\x00\x00\x80',
        stats_null_count     = 0,
        stats_distinct_count = 5,
        stats_max_value      = b'\xff\xff\xff\xff\xff',
        stats_min_value      = b'\x00\x00\x00\x00\x80',
        stats_is_max_exact   = True,
        stats_is_min_exact   = False,
    )
    chunk = hdr + payload
    page = _ExpectedPage(
        page_type  = _PageType.PLAIN,
        num_values = num_values,
        last       = True,
        payload    = bytearray(payload),
    )
    return _TestCase(
        chunk_num_values = num_values,
        chunk_bytes      = bytearray(chunk),
        pages            = [page],
    )


def _data_page_sparse_stats_case() -> _TestCase:
    """DataPageHeader whose Statistics writes only fids 1, 5, 8 — deltas 1, 4, 3.

    Forces the parser to dispatch on tag bytes 0x48 (binary, delta 4) and
    0x31 (bool-true, delta 3), not just the delta-1 forms 0x18 / 0x11.
    """
    num_values   = 42
    payload_size = 80
    encoding     = 0  # PLAIN

    payload = bytearray(range(payload_size % 256)) * (payload_size // 256 + 1)
    payload = payload[:payload_size]

    hdr = _make_data_page_header_sparse_stats(
        num_values         = num_values,
        uncompressed_size  = payload_size,
        compressed_size    = payload_size,
        encoding           = encoding,
        def_level_encoding = 0,
        rep_level_encoding = 0,
        crc                = 0x12345678,
        stats_max          = b'\xff\xff\xff\xff\xff\xff\xff\x7f',
        stats_max_value    = b'\xff\xff\xff\xff\xff\xff\xff\x7f',
        stats_is_min_exact = True,
    )
    chunk = hdr + payload
    page = _ExpectedPage(
        page_type  = _PageType.PLAIN,
        num_values = num_values,
        last       = True,
        payload    = bytearray(payload),
    )
    return _TestCase(
        chunk_num_values = num_values,
        chunk_bytes      = bytearray(chunk),
        pages            = [page],
    )


# Real column chunk 5 (EventDate, INT32) of row group 0 of ClickBench hits.parquet (written by
# parquet-cpp 1.5.1). 62 bytes: 14-byte dictionary page header + 6-byte Snappy payload, then a
# 35-byte data page header + 7-byte Snappy payload. The data page Statistics struct starts with
# `36 00`: null_count (fid 3, delta 3) is a Thrift i64, i.e. compact type 6, with value 0.
_CLICKBENCH_EVENT_DATE_CHUNK = bytes.fromhex(
    '15041508150c4c15021504120000'                                          # dict page header
    '040c1d3e0000'                                                          # dict payload
    '1500150a150e2c158080371504150615061c360028041d3e000018041d3e0000000000'  # data page header
    '05100180803700'                                                        # data payload
)

def _clickbench_event_date_case() -> _TestCase:
    return _TestCase(
        chunk_num_values = 450560,
        chunk_bytes      = bytearray(_CLICKBENCH_EVENT_DATE_CHUNK),
        pages            = [
            _ExpectedPage(
                page_type  = _PageType.DICT,
                num_values = 1,
                last       = False,
                payload    = bytearray(_CLICKBENCH_EVENT_DATE_CHUNK[14:20]),
            ),
            _ExpectedPage(
                page_type  = _PageType.HYBRID, # PLAIN_DICTIONARY
                num_values = 450560,
                last       = True,
                payload    = bytearray(_CLICKBENCH_EVENT_DATE_CHUNK[55:]),
            ),
        ],
    )


def _i64_statistics_sweep_case() -> _TestCase:
    """64 data pages with parquet-cpp style i64 Statistics (`16 00` null_count and a 6-byte
    distinct_count varint). Every page is 129 bytes (= 1 mod 64), so page i starts at offset i
    within a 64-byte AXI beat and every header byte is hit at every buffer alignment, including
    the refill cycles in the middle of a varint.
    """
    num_pages  = 64
    num_values = 1000
    page_size  = 2 * 64 + 1

    def header(payload_size: int) -> bytearray:
        return _make_data_page_header_i64_stats(
            num_values           = num_values,
            uncompressed_size    = payload_size,
            compressed_size      = payload_size,
            encoding             = 0,  # PLAIN
            stats_max            = b'\xff\xff\xff\xff\xff\xff\xff\x7f',
            stats_min            = b'\x00\x00\x00\x00\x00\x00\x00\x80',
            stats_null_count     = 0,
            stats_distinct_count = 1 << 40,
            stats_max_value      = b'\xff\xff\xff\xff\xff\xff\xff\x7f',
            stats_min_value      = b'\x00\x00\x00\x00\x00\x00\x00\x80',
        )

    payload_size = next(n for n in range(page_size) if len(header(n)) + n == page_size)
    hdr          = header(payload_size)

    chunk = bytearray()
    pages = []
    for i in range(num_pages):
        payload = bytearray((i + j) & 0xFF for j in range(payload_size))
        chunk += hdr + payload
        pages.append(_ExpectedPage(
            page_type  = _PageType.PLAIN,
            num_values = num_values,
            last       = i == num_pages - 1,
            payload    = payload,
        ))

    return _TestCase(
        chunk_num_values = num_pages * num_values,
        chunk_bytes      = chunk,
        pages            = pages,
    )


# ---------------------------------------------------------------------------
# Build test cases from nation.parquet
# ---------------------------------------------------------------------------

def _decode_leb128(data: bytes, pos: int) -> tuple[int, int]:
    result, shift = 0, 0
    while True:
        b = data[pos]
        result |= (b & 0x7F) << shift
        pos += 1
        shift += 7
        if not (b & 0x80):
            break
    return result, pos

def _zigzag_decode(n: int) -> int:
    return (n >> 1) ^ (-(n & 1))

def _skip_varint(data: bytes, pos: int) -> int:
    while data[pos] & 0x80:
        pos += 1
    return pos + 1

def _skip_field(data: bytes, pos: int) -> int:
    ctype = data[pos] & 0xF
    pos += 1
    if ctype in (4, 5, 6):
        pos = _skip_varint(data, pos)
    elif ctype == 0xC:
        while data[pos] != 0x00:
            pos = _skip_field(data, pos)
        pos += 1  # nested STOP
    return pos

def _parse_inner_struct(data: bytes, pos: int) -> tuple[dict, int]:
    fields: dict[int, object] = {}
    prev_fid = 0
    while pos < len(data):
        tag = data[pos]
        if tag == 0x00:
            pos += 1
            break
        delta_fid = (tag >> 4) & 0xF
        ctype = tag & 0xF
        if delta_fid == 0:
            raw, pos = _decode_leb128(data, pos + 1)
            fid = _zigzag_decode(raw)
        else:
            fid = prev_fid + delta_fid
            pos += 1
        prev_fid = fid
        if ctype in (4, 5, 6):
            val, pos = _decode_leb128(data, pos)
            fields[fid] = _zigzag_decode(val)
        elif ctype in (1, 2):
            fields[fid] = (ctype == 1)
        elif ctype == 0xC:
            while data[pos] != 0x00:
                pos = _skip_field(data, pos)
            pos += 1
            fields[fid] = 'struct'
        else:
            break
    return fields, pos

def _parse_page_header(data: bytes, offset: int) -> tuple[dict, int]:
    pos = offset
    outer: dict[int, object] = {}
    prev_fid = 0
    while pos < len(data):
        tag = data[pos]
        if tag == 0x00:
            pos += 1
            break
        delta_fid = (tag >> 4) & 0xF
        ctype = tag & 0xF
        if delta_fid == 0:
            raw, pos = _decode_leb128(data, pos + 1)
            fid = _zigzag_decode(raw)
        else:
            fid = prev_fid + delta_fid
            pos += 1
        prev_fid = fid
        if ctype in (4, 5, 6):
            val, pos = _decode_leb128(data, pos)
            outer[fid] = _zigzag_decode(val)
        elif ctype == 0xC:
            inner, pos = _parse_inner_struct(data, pos)
            outer[fid] = inner
        elif ctype in (1, 2):
            outer[fid] = (ctype == 1)
    return outer, pos

def _extract_parquet_column_chunks(parquet_path: str) -> list[_TestCase]:
    with open(parquet_path, 'rb') as fh:
        raw = bytearray(fh.read())

    pf = pq.ParquetFile(parquet_path)
    meta = pf.metadata
    cases: list[_TestCase] = []

    for col_idx in range(meta.num_columns):
        col = meta.row_group(0).column(col_idx)
        start = (
            col.dictionary_page_offset
            if col.dictionary_page_offset is not None
            else col.data_page_offset
        )
        size  = col.total_compressed_size
        chunk = bytes(raw[start : start + size])

        pages: list[_ExpectedPage] = []
        pos = 0
        total_num_values = 0

        while pos < size:
            outer, hdr_end = _parse_page_header(chunk, pos)
            if not outer:
                break
            thrift_type  = outer.get(1, 0)
            comp_size    = outer.get(3, 0)
            inner_key    = 7 if thrift_type == 2 else 5
            inner        = outer.get(inner_key, {})
            num_values   = inner.get(1, 0) if isinstance(inner, dict) else 0
            encoding     = inner.get(2, 0) if isinstance(inner, dict) else 0

            hw_type = _hw_page_type(thrift_type, encoding)
            payload_start = hdr_end
            payload_end   = pos + (hdr_end - pos) + comp_size
            payload       = bytearray(chunk[payload_start : payload_end])

            pages.append(_ExpectedPage(
                page_type  = hw_type,
                num_values = num_values,
                last       = False,
                payload    = payload,
            ))

            if hw_type != _PageType.DICT:
                total_num_values += num_values

            pos = payload_end

        if pages:
            pages[-1].last = True
            cases.append(_TestCase(
                chunk_num_values = total_num_values,
                chunk_bytes      = bytearray(chunk),
                pages            = pages,
            ))

    return cases


# ---------------------------------------------------------------------------
# Serialisation helpers
# ---------------------------------------------------------------------------

def _page_conf_record(page: _ExpectedPage) -> bytearray:
    """6-byte record matching the hardware serialiser: type(1) | num_values(4 LE) | last(1)."""
    rec = bytearray(6)
    rec[0] = int(page.page_type)
    rec[1:5] = page.num_values.to_bytes(4, 'little')
    rec[5] = 1 if page.last else 0
    return rec

def _chunk_conf_register(num_values: int) -> bytearray:
    """ColumnChunkDecoderConfig packed register value (single reg at offset 3).

    column_chunk_conf_t packs (MSB -> LSB) as:
      compression_t [1 bit] | num_values [32 bits] | type_t [3 bits]
    """
    compression = 0  # RAW
    type_t      = 2  # INT64 (unused here)
    packed = (compression << 35) | ((num_values & 0xFFFFFFFF) << 3) | (type_t & 0x7)
    return bytearray(packed.to_bytes(8, 'little'))


# ---------------------------------------------------------------------------
# Test case instances
# ---------------------------------------------------------------------------

_PARQUET_PATH = os.path.join(os.path.dirname(__file__), 'data', 'lineitem.parquet')

_SYNTHETIC_CASES = [
    _single_plain_page_case(),
    _single_hybrid_page_case(),
    _dict_plus_hybrid_case(),
    _large_plain_case(),
    _data_page_all_optional_fields_case(),
    _data_page_sparse_stats_case(),
    _deep_header_small_payload_case(),
    _page_boundary_aligned_case(),
    _clickbench_event_date_case(),
    _i64_statistics_sweep_case(),
]

_PARQUET_CASES = _extract_parquet_column_chunks(_PARQUET_PATH)


# ---------------------------------------------------------------------------
# Test class
# ---------------------------------------------------------------------------

class PageHeaderParserTestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga_tops/page_header_parser_test.sv"
    debug_mode = True

    def _run(self, tcs: list[_TestCase], sim_time_us: int | None = None) -> None:
        if sim_time_us is not None:
            self.overwrite_simulation_time(simulation_time.SimulationTime.fixed_time(
                sim_time_us, simulation_time.SimulationTimeUnit.MICROSECONDS))

        for tc in tcs:
            self.write_register(fpga_register.vFPGARegister(3, _chunk_conf_register(tc.chunk_num_values)))

            self.set_stream_input(0, tc.chunk_bytes)

            # Expected output stream 0: one transfer per page (each ends with last=1)
            # Expected output stream 1: one 6-byte page_conf record per page
            for page in tc.pages:
                self.set_expected_output(0, page.payload)
                self.set_expected_output(1, _page_conf_record(page))

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- Synthetic tests -----------------------------------------------------

    def test_single_plain_page(self):
        self._run([_SYNTHETIC_CASES[0]])

    def test_single_hybrid_page(self):
        self._run([_SYNTHETIC_CASES[1]])

    def test_dict_plus_hybrid(self):
        self._run([_SYNTHETIC_CASES[2]])

    def test_large_plain_page(self):
        self._run([_SYNTHETIC_CASES[3]])

    def test_data_page_all_optional_fields(self):
        """DataPageHeader with CRC and all 8 Statistics fields populated."""
        self._run([_SYNTHETIC_CASES[4]])

    def test_data_page_sparse_statistics(self):
        """Statistics with non-sequential fids (deltas 1, 4, 3) — exercises
        high-nibble dispatch in IS_END."""
        self._run([_SYNTHETIC_CASES[5]])

    def test_overfull_header_buffer(self):
        """Long header (CRC + full Statistics with binary fields) forces a buffer
        refill inside IS_END, leaving remaining_bytes > NUM_BYTES when
        PAYLOAD_DRAIN_BUF is entered."""
        self._run([_SYNTHETIC_CASES[6]])

    # -- lineitem.parquet tests ----------------------------------------------

    def test_parquet_l_orderkey(self):
        """Plain data page: INT64, no dictionary."""
        self._run([_PARQUET_CASES[0]])

    def test_parquet_l_discount(self):
        """Dictionary page + RLE_DICT data page: INT64."""
        self._run([_PARQUET_CASES[6]])

    def test_parquet_l_extendedprice(self):
        """Plain data page: INT64, no dictionary (large payload)."""
        self._run([_PARQUET_CASES[5]])

    def test_parquet_l_shipdate(self):
        """Plain data page: INT32, no dictionary."""
        self._run([_PARQUET_CASES[10]])

    def test_sequential_column_chunks(self):
        """Two different column chunks driven back-to-back in one simulation.
        Verifies that IDLE fully resets internal state between chunks so the
        second chunk is parsed correctly after the first completes."""
        self._run([_PARQUET_CASES[0], _PARQUET_CASES[6]])

    def test_beat_boundary_aligned_header(self):
        """The first page ends *exactly* on a 64-byte AXI-beat boundary (header 14 + 
        payload 50 = 64) and the following page header starts at byte 0 of the next beat. In that 
        alignment the parser used to get misaligned."""
        self._run([_SYNTHETIC_CASES[7]])

    def test_clickbench_i64_statistics(self):
        """Real ClickBench column chunk whose Statistics carry an i64 null_count (tag 0x36,
        compact type 6). The parser used to only skip i32 varints (type 5) and misread the
        null_count value 0x00 as a struct STOP."""
        self._run([_SYNTHETIC_CASES[8]])

    def test_i64_statistics_all_alignments(self):
        """parquet-cpp style i64 Statistics fields at every offset within a 64-byte AXI beat."""
        self._run([_SYNTHETIC_CASES[9]], sim_time_us=40)
