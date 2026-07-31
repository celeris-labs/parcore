from coyote_test import fpga_test_case, fpga_register, simulation_time
from random import randint, seed
from typing import List
from unit_test.fpga_stream import Stream, StreamType
from unit_test.io_writer import CoyoteOperator
from unit_test.simulation_time import SimulationTime, SimulationTimeUnit, FixedSimulationTime

import numpy as np

REG_OFFSET      = 3
REG_BUFFER_ADDR = 4

BEAT_SIZE  = 64
INLINE_LEN = 12

PREFIX_LEN = 4
DEFAULT_BUFFER_ADDR = 0x1000


# ---------------------------------------------------------------------------
# Encoding helpers
# ---------------------------------------------------------------------------

def _encode(strings: List[bytes]) -> bytearray:
    """Serialize strings in PLAIN format: 4-byte LE length prefix + payload."""
    buf = bytearray()
    for s in strings:
        buf += len(s).to_bytes(4, 'little')
        buf += s
    return buf


def _encode_lengths(strings: List[bytes]) -> bytearray:
    buf = bytearray()
    for s in strings:
        buf += len(s).to_bytes(4, 'little')
    return buf


def _expected_strings(strings: List[bytes], buffer_addr: int) -> List[int]:
    """The german_str_t records, serialised LSB-first as the hardware emits them.

    Canonical Umbra/German layout of each 16-byte record (byte 0 first):
      bytes  0..3  : length   - 4-byte LE string length
      bytes  4..7  : prefix   - first 4 string bytes (zero-padded)
      bytes  8..15 : payload  - inline bytes 4..11 (short) OR 8-byte LE buffer
                                address (long, len > 12)

    The buffer address advances by every string's length (all bytes are written
    to the buffer), so a long string at logical offset `cum` stores
    buffer_addr + cum.
    """
    out = bytearray()
    # Needs to start at 4 due to length prefixes, actual data starts at 4
    element_offset = 4
    for s in strings:
        n = len(s)
        rec = bytearray(16)
        rec[0:4] = n.to_bytes(4, 'little')
        rec[4:8] = (s[:4]).ljust(4, b'\x00')
        if n <= INLINE_LEN:
            rec[8:16] = (s[4:12]).ljust(8, b'\x00')
        else:
            rec[8:16] = (buffer_addr + element_offset).to_bytes(8, 'little')
        out += rec
        # + 4 for the length prefix
        element_offset += n + 4
    return list(out)


# ---------------------------------------------------------------------------
# Function which verifies that the generated input and output
# data for the tests are correct
# ---------------------------------------------------------------------------
def verify_test_data(strings, encoded_input, german_strs, buffer_addr) -> List[int]:
    assert len(german_strs) % 16 == 0, \
        f"Length of german string stream should \
        always be multiple of 16! len(german_str): {len(german_strs)}"
    for i in range(len(german_strs) // 16):
        string_struct = german_strs[i*16:(i+1)*16]
        length = int.from_bytes(string_struct[0:4], "little")
        prefix = bytes(string_struct[4:min(4 + length,8)])
        str_continuation_or_address = string_struct[8:]
        assert length == len(strings[i]), \
                f"length = {length} != {len(strings[i])} = len(strings[{i}])"
        assert prefix == strings[i][0:4], \
                f"prefix = {prefix} != {strings[i][0:4]} = strings[{i}][0:4]"
        
        if length <= INLINE_LEN:
            str_continuation = bytes(str_continuation_or_address[:max(0,length-PREFIX_LEN)])
            assert str_continuation == strings[i][4:12], \
                f"str_continuation = {str_continuation} != {strings[i][4:12]} = strings[{i}][4:12]"
        else:
            ptr = int.from_bytes(str_continuation_or_address, "little")
            ptr = ptr - buffer_addr
            extracted_string_from_input = bytes(encoded_input[ptr:ptr+length])
            assert extracted_string_from_input == strings[i], \
                f"extracted_string_from_input = {extracted_string_from_input} != {strings[i]} = strings[{i}]"


# ---------------------------------------------------------------------------
# Test case
# ---------------------------------------------------------------------------

class PlainStringDecoderTest(fpga_test_case.FPGATestCase):
    """
    Tests for StringDecoder.

    The vfpga top wires:
      - axis_host_recv[0] -> AXIToNData            -> in_data    (plain-encoded string data)
      - out_strings -> bytes -> NDataWidthConverter
                    -> NDataToAXI -> axis_host_send[0]           (german_str_t)
      - out_data    -> NDataToAXI -> axis_host_send[1]           (forwarded bytes)
    """

    alternative_vfpga_top_file = "vfpga_tops/plain_string_decoder_test.sv"
    debug_mode = True

    def setUp(self):
        ret = super().setUp()
        return ret

    # ------------------------------------------------------------------
    # Shared driver
    # ------------------------------------------------------------------

    def _run(self, strings: List[bytes], buffer_addr: int = DEFAULT_BUFFER_ADDR) -> None:
        self.write_register(fpga_register.vFPGARegister(
            REG_OFFSET, bytearray((len(strings)).to_bytes(4, 'little'))))
        self.write_register(fpga_register.vFPGARegister(
            REG_BUFFER_ADDR, bytearray(buffer_addr.to_bytes(8, 'little'))))

        input = _encode(strings)
        german_strs = _expected_strings(strings, buffer_addr)
        self.set_stream_input(0, input)

        self.set_expected_output(0, input)
        self.set_expected_output(
            1, Stream(StreamType.UNSIGNED_INT_8, german_strs))
        
        verify_test_data(strings, input, german_strs, buffer_addr)

        self.simulate_fpga()
        self.assert_simulation_output()

    # ------------------------------------------------------------------
    # Short strings (inline payload)
    # ------------------------------------------------------------------

    def test_single_short_string(self):
        """One short string: prefix + inline payload, no address."""
        self._run([b"hello"])

    def test_string_shorter_than_prefix(self):
        """Length < 4: prefix is partially filled and zero-padded, payload empty."""
        self._run([b"ab"])

    def test_string_exactly_prefix_len(self):
        """Length == 4: prefix full, inline payload all zero."""
        self._run([b"abcd"])

    def test_string_fills_inline(self):
        """Length == 12: the maximum inline string (4 prefix + 8 payload)."""
        self._run([b"abcdefghijkl"])

    def test_multiple_short_one_beat(self):
        """Several short strings whose bytes fit in a single data beat.
        Exercises Path A (stay on the beat) repeatedly."""
        self._run([b"foo", b"bar", b"baz"])

    def test_empty_among_nonempty(self):
        """Zero-length strings interleaved with real ones (data stays non-empty)."""
        self._run([b"", b"abc", b"", b"de"])

    # ------------------------------------------------------------------
    # Long strings (address payload)
    # ------------------------------------------------------------------

    def test_single_long_string(self):
        """Length 13 (> 12): payload is the buffer address, not inline bytes."""
        self._run([b"abcdefghijklm"])

    def test_long_string_spans_two_beats(self):
        """A 65-byte string spans two data beats: Path B then a continuation
        flush. Its view stores buffer_addr + 0."""
        self._run([b"a" * 65])

    def test_long_string_spans_many_beats(self):
        """A 200-byte string spans four beats, stressing the continuation path."""
        self._run([b"b" * 200])

    def test_mixed_short_and_long(self):
        """Mix of inline and address strings; checks the running buffer address
        advances by every string's length."""
        self._run([b"hi", b"x" * 20, b"yo", b"z" * 30, b"end"])

    # ------------------------------------------------------------------
    # Payloads that end exactly on a beat boundary
    # ------------------------------------------------------------------
    #
    # Every case above ends mid-beat (9, 6, 8, 16, 21, 17, 69, 204 bytes ...), so
    # nothing here ever covered a payload that is a whole number of beats. That
    # is the shape SF100 hangs on: in vfpga_top the decoder emitted only the
    # first beat of a 64-byte payload and never asserted last, which starves
    # HeapNormalizer and leaves StreamWriter parked on an unfinished transfer.
    # The 63-byte case is the control - one byte shorter, same string count.

    def test_payload_exactly_one_beat(self):
        """4-byte prefix + 60 bytes = 64, exactly one beat."""
        self._run([b"a" * 60])

    def test_payload_one_byte_short_of_a_beat(self):
        """Control: 63 bytes, so the final beat is partially filled."""
        self._run([b"a" * 59])

    def test_payload_exactly_two_beats(self):
        """A single string whose encoding is exactly 128 bytes."""
        self._run([b"b" * 124])

    def test_payload_exact_beats_multiple_strings(self):
        """Several strings summing to exactly 128 bytes, so the boundary falls
        between records rather than inside one."""
        self._run([b"c" * 60, b"d" * 28, b"e" * 20, b"f" * 4])

    # ------------------------------------------------------------------
    # Lookahead / beat-boundary behaviour
    # ------------------------------------------------------------------

    def test_short_string_uses_preview_bytes(self):
        """A short string that starts near the end of a beat, so its inline
        bytes are read from the Lookahead preview window of the next beat.
        String 1 (60 bytes, long) leaves string 2 starting at byte 60."""
        self._run([b"x" * 60, b"abcdefghij"])

    def test_string_ends_on_beat_boundary(self):
        """A string whose bytes end exactly on the 64-byte boundary (Path B with
        next_offset == STREAM_WIDTH), followed by another string."""
        self._run([b"a" * 64, b"tail"])

    # ------------------------------------------------------------------
    # Scale / throughput
    # ------------------------------------------------------------------

    def test_16_strings_fill_length_beat(self):
        self._run([b"ab"] * 16)

    def test_many_short_strings(self):
        strings = [bytes([(i + 1) % 256, (i * 3) % 256, (i * 7) % 256])
                   for i in range(50)]
        self._run(strings)

    def test_many_mixed_strings(self):
        """A larger page mixing every category to cover all FSM paths together."""
        self._run([
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
        ])

    def test_many_mixed_strings_2(self):
        """A larger page mixing every category to cover all FSM paths together."""
        self._run([
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
            b"a",
            b"hello world",            # 11, inline
            b"abcdefghijkl",           # 12, inline boundary
            b"abcdefghijklm",          # 13, address
            b"q" * 70,                 # long, multi-beat
            b"short",
            b"",
            b"the quick brown fox jumps over the lazy dog",
        ])

    def test_random_input(self):
        """A larger page mixing every category to cover all FSM paths together."""
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        RAND_SEED = 0xDEADBEEF
        NUM_STRINGS = 4
        STR_MIN_LEN = 0
        STR_MAX_LEN = 4096
        seed(RAND_SEED)
        input = []
        for _ in range(NUM_STRINGS):
            str_len = randint(STR_MIN_LEN, STR_MAX_LEN)
            print(str_len)
            input.append(np.random.bytes(str_len))
        
        encoded = _encode(input)
        print([hex(int(b)) for b in encoded[57*64:58*64]])
        self._run(input)
