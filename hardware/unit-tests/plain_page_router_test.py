from random import Random

from coyote_test import fpga_test_case, fpga_register

REG_CONF = 3

BEAT_SIZE = 64

# vfpga top stream wiring
IN = 0
IN_STR_DECODER = 1

OUT_STR_DECODER = 0
OUT_VALUES = 1
OUT_DICTIONARY = 2


def _rand(rng: Random, n: int) -> bytearray:
    return bytearray(rng.randrange(256) for _ in range(n))


def _conf(is_string: bool, is_dictionary: bool) -> int:
    # plain_page_conf_t packs (MSB -> LSB): is_string | is_dictionary
    return (int(is_string) << 1) | int(is_dictionary)


def plain_fixed(values: bytearray) -> dict:
    return {"conf": _conf(False, False), "in": values, OUT_VALUES: values}


def plain_string(page: bytearray, decoded: bytearray) -> dict:
    return {"conf": _conf(True, False), "in": page, OUT_STR_DECODER: page,
            "in_from_str_decoder": decoded, OUT_VALUES: decoded}


def dict_fixed(body: bytearray) -> dict:
    return {"conf": _conf(False, True), "in": body, OUT_DICTIONARY: body}


def dict_string(body: bytearray, decoded: bytearray) -> dict:
    return {"conf": _conf(True, True), "in": body, OUT_STR_DECODER: body,
            "in_from_str_decoder": decoded, OUT_DICTIONARY: decoded}


class PlainPageRouterTestCase(fpga_test_case.FPGATestCase):
    """
    Tests PlainPageRouter. One conf per page picks the route:

      data page / fixed    in -> out_values
      data page / string   in -> out_to_str_decoder, in_from_str_decoder -> out_values
      dictionary / fixed   in -> out_dictionary
      dictionary / string  in -> out_to_str_decoder, in_from_str_decoder -> out_dictionary

    The decoder stand-in on recv[1] may return more or fewer bytes than it was given, as the real
    decoder does.
    """

    alternative_vfpga_top_file = "vfpga_tops/plain_page_router_test.sv"
    debug_mode = True

    def _run_pages(self, pages: list[dict]):
        for page in pages:
            self.write_register(fpga_register.vFPGARegister(
                REG_CONF, bytearray(page["conf"].to_bytes(8, 'little'))))

            self.set_stream_input(IN, page["in"])
            if "in_from_str_decoder" in page:
                self.set_stream_input(IN_STR_DECODER, page["in_from_str_decoder"])

            for stream in (OUT_STR_DECODER, OUT_VALUES, OUT_DICTIONARY):
                if stream in page:
                    self.set_expected_output(stream, page[stream])

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- One page per route ---------------------------------------------------
    def test_plain_fixed(self):
        rng = Random(1)
        self._run_pages([plain_fixed(_rand(rng, 3 * BEAT_SIZE + 12))])

    def test_plain_string(self):
        rng = Random(2)
        self._run_pages([plain_string(_rand(rng, 5 * BEAT_SIZE + 3), _rand(rng, 2 * BEAT_SIZE + 32))])

    def test_dict_fixed(self):
        rng = Random(3)
        self._run_pages([dict_fixed(_rand(rng, 2 * BEAT_SIZE + 8))])

    def test_dict_string(self):
        rng = Random(4)
        self._run_pages([dict_string(_rand(rng, 40), _rand(rng, 3 * BEAT_SIZE))])

    # -- Beat boundaries ------------------------------------------------------
    def test_partial_and_exact_beats(self):
        rng = Random(5)
        self._run_pages([
            plain_string(_rand(rng, BEAT_SIZE), _rand(rng, BEAT_SIZE)),
            plain_string(_rand(rng, 1), _rand(rng, 16)),
            plain_fixed(_rand(rng, BEAT_SIZE)),
            plain_fixed(_rand(rng, 4)),
        ])

    # -- Realistic chunk shapes -----------------------------------------------
    def test_string_chunk(self):
        rng = Random(6)
        self._run_pages([
            dict_string(_rand(rng, 2 * BEAT_SIZE), _rand(rng, BEAT_SIZE + 16)),
            plain_string(_rand(rng, 80), _rand(rng, 64)),
            plain_string(_rand(rng, 3 * BEAT_SIZE + 7), _rand(rng, 2 * BEAT_SIZE)),
        ])

    def test_fixed_chunk(self):
        rng = Random(7)
        self._run_pages([
            dict_fixed(_rand(rng, 96)),
            plain_fixed(_rand(rng, BEAT_SIZE + 8)),
            plain_fixed(_rand(rng, 30)),
        ])

    # -- Route switching: a page enters while the previous one is still in the decoder ---------
    def test_all_routes_back_to_back(self):
        rng = Random(8)
        self._run_pages([
            dict_string(_rand(rng, 64), _rand(rng, 24)),
            plain_fixed(_rand(rng, 25)),
            plain_string(_rand(rng, 33), _rand(rng, 4 * BEAT_SIZE)),
            dict_fixed(_rand(rng, 2 * BEAT_SIZE)),
            plain_string(_rand(rng, 4 * BEAT_SIZE), _rand(rng, 20)),
            dict_string(_rand(rng, 16), _rand(rng, 48)),
            plain_fixed(_rand(rng, 3 * BEAT_SIZE + 1)),
        ])

    def test_many_small_pages(self):
        rng = Random(9)
        makers = [lambda: plain_fixed(_rand(rng, rng.randrange(1, 100))),
                  lambda: plain_string(_rand(rng, rng.randrange(1, 100)), _rand(rng, rng.randrange(1, 200))),
                  lambda: dict_fixed(_rand(rng, rng.randrange(1, 100))),
                  lambda: dict_string(_rand(rng, rng.randrange(1, 100)), _rand(rng, rng.randrange(1, 200)))]
        self._run_pages([rng.choice(makers)() for _ in range(40)])
