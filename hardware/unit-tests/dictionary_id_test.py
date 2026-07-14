from random import Random

from coyote_test import fpga_test_case, fpga_stream, fpga_register

REG_DATA_TYPE = 3

BYTE_T = 0
INT32_T = 1
INT64_T = 2
FLOAT_T = 3
DOUBLE_T = 4
GERMAN_STR_T = 5

_FACTORS = {
    BYTE_T: 1,
    INT32_T: 1,
    INT64_T: 2,
    FLOAT_T: 1,
    DOUBLE_T: 2,
    GERMAN_STR_T: 4,
}


def _expand(indices: list[int], factor: int) -> list[int]:
    return [factor * v + j for v in indices for j in range(factor)]


class DictionaryIDTestCase(fpga_test_case.FPGATestCase):
    """
    Tests DictionaryID: expands dictionary indices of a column's data type
    into indices of the 32-bit words the dictionary stores. 32-bit types pass
    through, 64-bit types expand x2 and german strings x4. One data_type is
    consumed per page (an input segment terminated by last).
    """

    alternative_vfpga_top_file = "vfpga_tops/dictionary_id_test.sv"
    debug_mode = True

    def _run_pages(self, pages: list[tuple[int, list[int]]]):
        for data_type, indices in pages:
            self.write_register(fpga_register.vFPGARegister(
                REG_DATA_TYPE, bytearray(data_type.to_bytes(4, 'little'))))
            self.set_stream_input(0, fpga_stream.Stream(
                fpga_stream.StreamType.UNSIGNED_INT_32, indices))
            self.set_expected_output(0, fpga_stream.Stream(
                fpga_stream.StreamType.UNSIGNED_INT_32,
                _expand(indices, _FACTORS[data_type])))

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- 32-bit path (pass-through) -------------------------------------------
    def test_int32_partial_beat(self):
        self._run_pages([(INT32_T, list(range(8)))])

    def test_int32_multi_beat(self):
        rng = Random(1)
        self._run_pages([(INT32_T, [rng.randint(0, 100_000) for _ in range(40)])])

    def test_byte_uses_forwarding_path(self):
        self._run_pages([(BYTE_T, list(range(16)))])

    def test_float_uses_forwarding_path(self):
        self._run_pages([(FLOAT_T, list(range(20)))])

    # -- 64-bit path (factor 2) -----------------------------------------------
    def test_int64_partial_beat(self):
        self._run_pages([(INT64_T, list(range(8)))])

    def test_int64_full_beats(self):
        rng = Random(2)
        self._run_pages([(INT64_T, [rng.randint(0, 100_000) for _ in range(32)])])

    def test_int64_partial_final_beat(self):
        rng = Random(3)
        self._run_pages([(INT64_T, [rng.randint(0, 100_000) for _ in range(37)])])

    def test_double(self):
        rng = Random(4)
        self._run_pages([(DOUBLE_T, [rng.randint(0, 100_000) for _ in range(21)])])

    # -- 128-bit path (factor 4, german strings) -------------------------------
    def test_german_str_partial_beat(self):
        self._run_pages([(GERMAN_STR_T, list(range(6)))])

    def test_german_str_multi_beat(self):
        rng = Random(5)
        self._run_pages([(GERMAN_STR_T, [rng.randint(0, 100_000) for _ in range(37)])])

    # -- Page sequencing --------------------------------------------------------
    def test_back_to_back_same_type(self):
        rng = Random(6)
        self._run_pages([
            (INT64_T, [rng.randint(0, 100_000) for _ in range(20)]),
            (INT64_T, [rng.randint(0, 100_000) for _ in range(13)]),
        ])

    def test_type_switch_between_pages(self):
        rng = Random(7)
        self._run_pages([
            (INT32_T, [rng.randint(0, 100_000) for _ in range(10)]),
            (GERMAN_STR_T, [rng.randint(0, 100_000) for _ in range(9)]),
            (INT64_T, [rng.randint(0, 100_000) for _ in range(17)]),
            (INT32_T, [rng.randint(0, 100_000) for _ in range(16)]),
        ])
