from coyote_test import simulation_time

import plain_string_decoder_test


class ParallelStringDecoderTest(plain_string_decoder_test.PlainStringDecoderTest):
    """
    Runs the PlainStringDecoder tests on the ParallelStringDecoder, which replaces it with the same
    registers and outputs (see vfpga_tops/parallel_string_decoder_test.sv).
    """

    alternative_vfpga_top_file = "vfpga_tops/parallel_string_decoder_test.sv"

    def setUp(self):
        ret = super().setUp()
        self.overwrite_simulation_time(simulation_time.SimulationTime.till_finished())
        return ret
