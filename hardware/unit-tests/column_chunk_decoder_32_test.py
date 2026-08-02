"""ColumnChunkDecoder at DATABEAT_SIZE=32 -- the width vfpga_top.svh actually
instantiates. Every other decoder suite runs at 64, so nothing covered the
narrow configuration until vfpga_top hung on a chunk that the 64-byte suite
decodes correctly.

Only the lineitem_stress cases are duplicated here rather than the whole 64-byte
suite: this exists to pin down one failure, not to double the suite's runtime.
Import the base class through the module so unittest does not also collect the
64-byte tests into this project, which would run them against the wrong top.
"""

import os
import unittest

from coyote_test import fpga_test_case

from coyote_test import simulation_time

import column_chunk_decoder_test as ccd
from column_chunk_decoder_test import (
    _stress_chunk,
    stress_dict_chunks,
)


class ColumnChunkDecoder32TestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga_tops/column_chunk_decoder_32_test.sv"
    debug_mode = True

    # Identical driving sequence; only the top differs.
    run_chunks = ccd.ColumnChunkDecoderTestCase.run_chunks

    def _run_stress_column(self, col: int, expected: list[int]):
        self.run_chunks([_stress_chunk(col)], [expected])

    def test_stress_dict_32_entries(self):
        self._run_stress_column(*stress_dict_chunks()[0][1:])

    def test_stress_dict_11_entries(self):
        self._run_stress_column(*stress_dict_chunks()[1][1:])

    def test_stress_dict_7_entries(self):
        """The chunk vfpga_top hangs on."""
        self._run_stress_column(*stress_dict_chunks()[2][1:])

    def test_stress_dict_all_three_back_to_back(self):
        cases = stress_dict_chunks()
        self.run_chunks([_stress_chunk(c) for _, c, _ in cases],
                        [exp for _, _, exp in cases])
