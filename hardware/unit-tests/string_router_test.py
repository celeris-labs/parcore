from random import Random

from coyote_test import fpga_test_case, fpga_register

REG_PAGE_CONF = 3

# page_type_t
PAGE_TYPE_HYBRID = 0
PAGE_TYPE_DICT = 1
PAGE_TYPE_PLAIN = 2

# type_t
BYTE_T = 0
INT32_T = 1
INT64_T = 2
FLOAT_T = 3
DOUBLE_T = 4
GERMAN_STR_T = 5

BEAT_SIZE = 64

# vfpga top stream wiring
IN_PLAIN = 0
IN_DICT = 1
IN_STR_DECODER = 2

OUT_TO_STR_DECODER = 0
OUT_TO_PLAIN = 1
OUT_TO_DICT = 2


def _rand(rng: Random, n: int) -> bytearray:
    return bytearray(rng.randrange(256) for _ in range(n))


def _page_conf(page_type: int, typ: int, num_values: int = 0, last: int = 0) -> int:
    # page_type_info_t packs (MSB -> LSB):
    #   type_t [3 bits] | page_type_t [2 bits]
    return ((typ & 0x7) << 2) | (page_type & 0x3)


def plain_fixed(typ: int, values: bytearray) -> dict:
    """PLAIN page of a fixed-width type: stripped bytes go straight to out_values."""
    return {"page_type": PAGE_TYPE_PLAIN, "typ": typ}


def plain_string(page_bytes: bytearray, decoded: bytearray) -> dict:
    """PLAIN page of german strings: stripped bytes are handed to the string
    decoder, the decoded records come back and become the page's values."""
    return {"page_type": PAGE_TYPE_PLAIN, "typ": GERMAN_STR_T,
            "in_from_plain": page_bytes, "out_to_str_decoder": page_bytes,
            "in_from_str_decoder": decoded, "out_to_plain": decoded}


def dict_string(body_bytes: bytearray, decoded: bytearray) -> dict:
    return {"page_type": PAGE_TYPE_DICT, "typ": GERMAN_STR_T,
            "in_from_dict_body": body_bytes, "out_to_str_decoder": body_bytes,
            "in_from_str_decoder": decoded, "out_to_dict_body": decoded}


def dict_fixed(typ: int) -> dict:
    """DICT page of a fixed-width type: the body bypasses this module entirely,
    so the router only consumes the page config."""
    return {"page_type": PAGE_TYPE_DICT, "typ": typ}


def hybrid(typ: int, values: bytearray) -> dict:
    """HYBRID page: the ids were resolved by the dictionary, so the looked-up
    values are forwarded straight to out_values."""
    return {"page_type": PAGE_TYPE_HYBRID, "typ": typ}


class StringRouterTestCase(fpga_test_case.FPGATestCase):
    """
    Tests StringRouter (hardware/src/hdl/string_router.sv):
    the byte-level crossbar between PlainRouter, DictionaryBody, and the
    PlainStringDecoder. One page_conf is consumed per page and picks the route:

      ANY    / fixed   none
      HYBRID / ANY     none
      PLAIN  / german  in_from_plain        -> out_to_str_decoder
                       in_from_str_decoder  -> out_to_plain
      DICT   / german  in_from_dict_body    -> out_to_str_decoder
                       in_from_str_decoder  -> out_to_dict_body

    The router never touches the bytes, so every expected output is its input
    bytes unchanged. Page boundaries are the stream `last` beats: one page_conf
    per last-terminated transfer on each active stream.

    vfpga top wiring:
      recv[0] -> in_from_plain
      recv[1] -> in_from_dict_body
      recv[2] -> in_from_str_decoder

      out_to_str_decoder    -> send[0]
      out_to_plain          -> send[1]
      out_to_dict_body      -> send[2]
    """

    alternative_vfpga_top_file = "vfpga_tops/string_router_test.sv"
    debug_mode = True

    def _run_pages(self, pages: list[dict]):
        for i, page in enumerate(pages):
            conf = _page_conf(page["page_type"], page["typ"],
                              last=1 if i == len(pages) - 1 else 0)
            self.write_register(fpga_register.vFPGARegister(
                REG_PAGE_CONF, bytearray(conf.to_bytes(8, 'little'))))

            for key, stream in (("in_from_plain", IN_PLAIN),
                                ("in_from_dict_body", IN_DICT),
                                ("in_from_str_decoder", IN_STR_DECODER)):
                if key in page:
                    self.set_stream_input(stream, page[key])

            for key, stream in (("out_to_str_decoder", OUT_TO_STR_DECODER),
                                ("out_to_plain", OUT_TO_PLAIN),
                                ("out_to_dict_body", OUT_TO_DICT)):
                if key in page:
                    self.set_expected_output(stream, page[key])

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- PLAIN / german: from_plain -> decoder, decoded -> to_plain -----------
    def test_plain_string_partial_beat(self):
        rng = Random(5)
        self._run_pages([plain_string(_rand(rng, 40), _rand(rng, 16))])

    def test_plain_string_exact_beat(self):
        rng = Random(6)
        self._run_pages([plain_string(_rand(rng, BEAT_SIZE), _rand(rng, BEAT_SIZE))])

    def test_plain_string_multi_beat(self):
        rng = Random(7)
        self._run_pages([plain_string(_rand(rng, 5 * BEAT_SIZE + 3),
                                      _rand(rng, 2 * BEAT_SIZE + 32))])

    def test_plain_string_decoded_larger_than_page(self):
        rng = Random(8)
        self._run_pages([plain_string(_rand(rng, 48), _rand(rng, 3 * BEAT_SIZE))])

    # -- DICT / german: from_plain -> decoder, decoded -> to_plain -----------
    def test_dict_string_partial_beat(self):
        rng = Random(5)
        self._run_pages([dict_string(_rand(rng, 40), _rand(rng, 16))])

    def test_dict_string_exact_beat(self):
        rng = Random(6)
        self._run_pages([dict_string(_rand(rng, BEAT_SIZE), _rand(rng, BEAT_SIZE))])

    def test_dict_string_multi_beat(self):
        rng = Random(7)
        self._run_pages([dict_string(_rand(rng, 5 * BEAT_SIZE + 3),
                                      _rand(rng, 2 * BEAT_SIZE + 32))])

    def test_dict_string_decoded_larger_than_page(self):
        rng = Random(8)
        self._run_pages([dict_string(_rand(rng, 48), _rand(rng, 3 * BEAT_SIZE))])

    # -- Realistic chunk shapes ----------------------------------------------
    def test_chunk_of_plain_fixed_pages(self):
        rng = Random(14)
        self._run_pages([
            plain_fixed(INT32_T, _rand(rng, 30)),
            plain_fixed(INT32_T, _rand(rng, BEAT_SIZE + 8)),
            plain_fixed(INT32_T, _rand(rng, 12)),
        ])

    def test_chunk_of_plain_string_pages(self):
        rng = Random(15)
        self._run_pages([
            plain_string(_rand(rng, BEAT_SIZE), _rand(rng, 32)),
            plain_string(_rand(rng, 2 * BEAT_SIZE + 5), _rand(rng, 48)),
            plain_string(_rand(rng, 17), _rand(rng, BEAT_SIZE + 16)),
        ])

    def test_fixed_dict_then_hybrid_pages(self):
        rng = Random(16)
        self._run_pages([
            dict_fixed(INT64_T),
            hybrid(INT64_T, _rand(rng, BEAT_SIZE)),
            hybrid(INT64_T, _rand(rng, 40)),
        ])

    def test_string_dict_then_hybrid_pages(self):
        rng = Random(17)
        self._run_pages([
            dict_string(_rand(rng, 2 * BEAT_SIZE), _rand(rng, BEAT_SIZE)),
            hybrid(GERMAN_STR_T, _rand(rng, BEAT_SIZE + 32)),
            hybrid(GERMAN_STR_T, _rand(rng, 16)),
        ])

    def test_string_dict_then_plain_string_pages(self):
        rng = Random(18)
        self._run_pages([
            dict_string(_rand(rng, 96), _rand(rng, 32)),
            plain_string(_rand(rng, 80), _rand(rng, 64)),
            plain_string(_rand(rng, 24), _rand(rng, 16)),
        ])

    # -- Route switching ------------------------------------------------------
    def test_alternating_plain_types(self):
        rng = Random(19)
        self._run_pages([
            plain_fixed(INT32_T, _rand(rng, 40)),
            plain_string(_rand(rng, 70), _rand(rng, 32)),
            plain_fixed(INT64_T, _rand(rng, BEAT_SIZE)),
            plain_string(_rand(rng, 16), _rand(rng, BEAT_SIZE + 16)),
        ])

    def test_all_page_types(self):
        rng = Random(20)
        self._run_pages([
            # in_from_dict_body -> out_to_str_decoder 64, in_from_str_decoder -> out_to_dict_body 24
            dict_string(_rand(rng, 64), _rand(rng, 24)),
            # none
            hybrid(GERMAN_STR_T, _rand(rng, 48)),
            # in_from_stripped -> out_to_str_decoder 33, in_from_str_decoder -> out_values 20
            plain_string(_rand(rng, 33), _rand(rng, 20)),
            # none
            dict_fixed(DOUBLE_T),
            # none
            hybrid(DOUBLE_T, _rand(rng, 2 * BEAT_SIZE)),
            # in_from_stripped ->  out_values 25
            plain_fixed(DOUBLE_T, _rand(rng, 25)),
        ])
