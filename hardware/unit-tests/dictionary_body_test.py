from random import Random

from coyote_test import fpga_test_case, fpga_register

REG_DTYPE = 3

BYTE_T = 0
INT32_T = 1
INT64_T = 2
FLOAT_T = 3
DOUBLE_T = 4
GERMAN_STR_T = 5

BEAT_SIZE = 64


def _rand(rng: Random, n: int) -> bytearray:
    return bytearray(rng.randrange(256) for _ in range(n))


class DictionaryBodyRouterTestCase(fpga_test_case.FPGATestCase):
    """
    Tests DictionaryBodyRouter: routes a dictionary body according to its page
    data type.

      - Non-german pages: in_body is forwarded verbatim to out_to_dict (through
        the DICT_BODY_SKID_CNT skid stages) and out_to_psd stays idle.
      - German pages: in_body is forwarded to out_to_psd (the PlainStringDecoder),
        and the decoded strings that come back on in_german_strings are forwarded
        to out_to_dict.

    The router is a pure byte router, so every expected output is the input bytes
    unchanged. One dtype is consumed per page (a stream segment ending in last).

    vfpga top wiring:
      recv[0] -> in_body,  recv[1] -> in_german_strings
      out_to_dict -> send[0],  out_to_psd -> send[1]
    """

    alternative_vfpga_top_file = "vfpga_tops/dictionary_body_test.sv"
    debug_mode = True

    def _run_pages(self, pages: list[tuple[int, bytearray, bytearray | None]]):
        """pages: list of (dtype, body, german_strings). german_strings is None
        for non-german pages and the bytes returned on in_german_strings for
        german pages."""
        for dtype, body, german in pages:
            self.write_register(fpga_register.vFPGARegister(
                REG_DTYPE, bytearray(dtype.to_bytes(4, 'little'))))
            self.set_stream_input(0, body)

            if dtype == GERMAN_STR_T:
                self.set_stream_input(1, german)
                self.set_expected_output(0, german)  # out_to_dict
                self.set_expected_output(1, body)     # out_to_psd
            else:
                self.set_expected_output(0, body)     # out_to_dict

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- Non-german pass-through (in_body -> out_to_dict) ----------------------
    def test_non_german_partial_beat(self):
        rng = Random(1)
        self._run_pages([(INT32_T, _rand(rng, 20), None)])

    def test_non_german_exact_beat(self):
        rng = Random(2)
        self._run_pages([(BYTE_T, _rand(rng, BEAT_SIZE), None)])

    def test_non_german_multi_beat_partial_final(self):
        rng = Random(3)
        self._run_pages([(INT64_T, _rand(rng, 3 * BEAT_SIZE + 17), None)])

    def test_non_german_multi_beat_exact(self):
        rng = Random(4)
        self._run_pages([(DOUBLE_T, _rand(rng, 4 * BEAT_SIZE), None)])

    def test_non_german_float(self):
        rng = Random(5)
        self._run_pages([(FLOAT_T, _rand(rng, 100), None)])

    # -- German (in_body -> out_to_psd, in_german_strings -> out_to_dict) ------
    def test_german_partial_beats(self):
        rng = Random(6)
        self._run_pages([(GERMAN_STR_T, _rand(rng, 40), _rand(rng, 16))])

    def test_german_exact_beats(self):
        rng = Random(7)
        self._run_pages([(GERMAN_STR_T, _rand(rng, BEAT_SIZE), _rand(rng, BEAT_SIZE))])

    def test_german_multi_beat(self):
        rng = Random(8)
        self._run_pages([(GERMAN_STR_T, _rand(rng, 5 * BEAT_SIZE + 3), _rand(rng, 2 * BEAT_SIZE + 32))])

    def test_german_strings_larger_than_body(self):
        rng = Random(9)
        self._run_pages([(GERMAN_STR_T, _rand(rng, 48), _rand(rng, 3 * BEAT_SIZE))])

    # -- Page sequencing ------------------------------------------------------
    def test_back_to_back_non_german(self):
        rng = Random(10)
        self._run_pages([
            (INT32_T, _rand(rng, 30), None),
            (INT64_T, _rand(rng, BEAT_SIZE + 8), None),
            (BYTE_T, _rand(rng, 12), None),
        ])

    def test_back_to_back_german(self):
        rng = Random(11)
        self._run_pages([
            (GERMAN_STR_T, _rand(rng, BEAT_SIZE), _rand(rng, 32)),
            (GERMAN_STR_T, _rand(rng, 2 * BEAT_SIZE + 5), _rand(rng, 48)),
        ])

    def test_alternating_types(self):
        rng = Random(12)
        self._run_pages([
            (INT32_T, _rand(rng, 40), None),
            (GERMAN_STR_T, _rand(rng, 70), _rand(rng, 32)),
            (INT64_T, _rand(rng, BEAT_SIZE), None),
            (GERMAN_STR_T, _rand(rng, 16), _rand(rng, BEAT_SIZE + 16)),
        ])

    def test_type_switch_sequence(self):
        rng = Random(13)
        self._run_pages([
            (GERMAN_STR_T, _rand(rng, 90), _rand(rng, 48)),
            (BYTE_T, _rand(rng, 25), None),
            (DOUBLE_T, _rand(rng, 2 * BEAT_SIZE), None),
            (GERMAN_STR_T, _rand(rng, BEAT_SIZE + 1), _rand(rng, 16)),
            (INT32_T, _rand(rng, 33), None),
        ])
