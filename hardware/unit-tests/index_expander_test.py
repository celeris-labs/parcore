from random import Random

from coyote_test import fpga_test_case, fpga_stream


def _expand(indices: list[int], factor: int) -> list[int]:
    """Reference model: each input index v -> {factor*v, ..., factor*v+factor-1}."""
    out: list[int] = []
    for v in indices:
        for j in range(factor):
            out.append(factor * v + j)
    return out


class IndexExpanderTestCase(fpga_test_case.FPGATestCase):
    """
    Tests Index Expander: turns indices addressing IN_WIDTH-bit elements into
    indices addressing the OUT_WIDTH-bit elements they are composed of. The
    expansion factor is FACTOR = IN_WIDTH / OUT_WIDTH, configured per test via
    SystemVerilog defines (changing them forces a re-compile).
    """

    alternative_vfpga_top_file = "vfpga_tops/index_expander_test.sv"
    debug_mode = True

    def _configure(self, in_width: int, out_width: int):
        self.set_system_verilog_defines({
            "INDEX_EXPANDER_IN_WIDTH": str(in_width),
            "INDEX_EXPANDER_OUT_WIDTH": str(out_width),
        })

    def _run(self, indices: list[int], factor: int):
        self.set_stream_input(
            0, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_32, indices)
        )
        self.set_expected_output(
            0, fpga_stream.Stream(fpga_stream.StreamType.UNSIGNED_INT_32, _expand(indices, factor))
        )
        self.simulate_fpga()
        self.assert_simulation_output()

    # -- FACTOR 2 (128 -> 64) -------------------------------------------------
    def test_factor2_single_beat(self):
        # 8 indices: half a beat -> a single emitted chunk.
        self._configure(128, 64)
        self._run(list(range(8)), 2)

    def test_factor2_multi_beat_partial(self):
        # 40 indices: two full beats (two chunks each) + a partial final beat.
        self._configure(128, 64)
        self._run(list(range(40)), 2)

    def test_factor2_random(self):
        # Arbitrary (non-sequential) indices, final beat partial (37 % 16 != 0).
        self._configure(128, 64)
        rng = Random(1)
        self._run([rng.randint(0, 100_000) for _ in range(37)], 2)

    # -- FACTOR 4 (128 -> 32) -------------------------------------------------
    # This is the string decode path's production configuration: german-string
    # ids expand x4 into raw int32 dictionary-slot ids.
    def test_factor4_partial(self):
        # 18 indices: one full beat (four chunks) + a final beat of two indices,
        # so only the first chunk is emitted (trailing empty chunks elided).
        self._configure(128, 32)
        self._run(list(range(18)), 4)

    def test_factor4_random(self):
        # Arbitrary (non-sequential) german-string ids, final beat partial.
        self._configure(128, 32)
        rng = Random(2)
        self._run([rng.randint(0, 100_000) for _ in range(37)], 4)

    # -- FACTOR 1 (64 -> 64): pass-through ------------------------------------
    def test_factor1_passthrough(self):
        self._configure(64, 64)
        rng = Random(1)
        self._run([rng.randint(0, 100_000) for _ in range(1064)], 1)
