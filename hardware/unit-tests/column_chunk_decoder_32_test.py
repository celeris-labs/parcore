"""ColumnChunkDecoder at DATABEAT_SIZE=32 -- the width vfpga_top.svh actually
instantiates. Every other decoder suite runs at 64, so nothing covered the
narrow configuration until vfpga_top hung on a chunk that the 64-byte suite
decodes correctly.

Only the lineitem_stress cases are duplicated here rather than the whole 64-byte
suite: this exists to pin down one failure, not to double the suite's runtime.
Import the base class through the module so unittest does not also collect the
64-byte tests into this project, which would run them against the wrong top.
"""

from libstf_utils.configured_test_case import ConfiguredTestCase

import column_chunk_decoder_test as ccd
from column_chunk_decoder_test import (
    _stress_chunk,
    stress_dict_chunks,
)


class ColumnChunkDecoder32TestCase(ConfiguredTestCase):
    alternative_vfpga_top_file = "vfpga_tops/column_chunk_decoder_32_test.sv"
    debug_mode = True

    # Identical driving sequence; only the top differs.
    configure = ccd.ColumnChunkDecoderTestCase.configure
    finish_input = ccd.ColumnChunkDecoderTestCase.finish_input
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

    # -- hits.parquet CounterID -----------------------------------------------
    #
    # Hangs on hardware (32 B bitstream). These are the first two row groups of the
    # REQUIRED INT32 column, verbatim: a dictionary page of 3/5 entries and a single
    # data page whose RLE/bit-packed hybrid indices are a short RLE run, one
    # bit-packed group and very long RLE runs, e.g. [rle 9][bp 8][rle 450543].
    def _run_counterid(self, row_groups: list[int]):
        chunks = [ccd._ColumnChunk(
                      compression=True,
                      num_values=sum(n for _, n in _COUNTERID_RUNS[rg]),
                      chunk_bytes=bytearray(_COUNTERID_CHUNKS[rg]),
                      stream_type=ccd.fpga_stream.StreamType.SIGNED_INT_32,
                      is_required=True)
                  for rg in row_groups]
        expected = [[v for v, n in _COUNTERID_RUNS[rg] for _ in range(n)] for rg in row_groups]
        self.run_chunks(chunks, expected)

    def test_hits_counterid_rg0(self):
        self._run_counterid([0])

    def test_hits_counterid_rg1(self):
        self._run_counterid([1])

    def test_hits_counterid_rg203(self):
        """Hangs on hardware: its dictionary page is 8 entries, exactly one 32 B beat."""
        self._run_counterid([203])


_COUNTERID_CHUNKS = {
    0: bytes.fromhex(
        "15041518151c4c150615041200000c2c1100000014000000260000001500151415182c158080371504150615061c"
        "18042600000018041100000016002804260000001804110000000000000a240212000355a5deff3602"),
    1: bytes.fromhex(
        "15041528152c4c150a1504120000144c2600000031000000340000003b0000003e00000015001528152c2c159cdd4a"
        "1504150615061c18043e000000180426000000160028043e000000180426000000000000144c03928107000589"
        "244992b46dccc509039e963a04"),
}

_COUNTERID_CHUNKS[203] = bytes.fromhex(
    "1504154015444c15101504120000207c5c8e0200718e020091b80200c3e60200f8ee02001eef020051ef02007e0b"
    "03001500153e15422c158080291504150615061c18047e0b030018045c8e0200160028047e0b030018045c8e0200"
    "0000001f78039c8d0100ec710180800a028080050388e70204961505e2830206f8801307")

# (value, count) runs of the decoded values
_COUNTERID_RUNS = {
    0: [(17, 9), (20, 6), (38, 450545)],
    1: [(38, 57417), (49, 2), (52, 10), (59, 78186), (62, 476559)],
    203: [(167516, 9038), (167537, 7286), (178321, 81920), (190147, 40960), (192248, 22980),
          (192286, 1355), (192337, 16625), (199550, 155708)],
}
