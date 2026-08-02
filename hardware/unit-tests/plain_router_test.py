from random import Random

from coyote_test import fpga_test_case, fpga_register

REG_CONF = 3

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
IN_STRIPPED = 0
IN_STR_DECODER = 1

OUT_VALUES = 0
OUT_STR_DECODER = 1


def _rand(rng: Random, n: int) -> bytearray:
    return bytearray(rng.randrange(256) for _ in range(n))


def plain_fixed(typ: int, values: bytearray) -> dict:
    """PLAIN page of a fixed-width type: stripped bytes go straight to out_values."""
    return {"page_type": PAGE_TYPE_PLAIN, "typ": typ,
            "stripped": values, "values": values}


def plain_string(page_bytes: bytearray, decoded: bytearray) -> dict:
    """PLAIN page of german strings: stripped bytes are handed to the string
    decoder, the decoded records come back and become the page's values."""
    return {"page_type": PAGE_TYPE_PLAIN, "typ": GERMAN_STR_T,
            "stripped": page_bytes, "to_str_decoder": page_bytes,
            "from_str_decoder": decoded, "values": decoded}


def dict_string(body_bytes: bytearray, decoded: bytearray) -> dict:
    """DICT page of german strings: the body travels via the StringRouter, so
    this module sees neither data nor config."""
    return {"page_type": PAGE_TYPE_DICT, "typ": GERMAN_STR_T}


def dict_fixed(typ: int) -> dict:
    """DICT page of a fixed-width type: the body bypasses this module entirely."""
    return {"page_type": PAGE_TYPE_DICT, "typ": typ}


def hybrid(typ: int, values: bytearray) -> dict:
    """HYBRID page: the ids were resolved by the dictionary and reach the output
    multiplexer directly, bypassing this module."""
    return {"page_type": PAGE_TYPE_HYBRID, "typ": typ}


class PlainRouterTestCase(fpga_test_case.FPGATestCase):
    """
    Tests PlainRouter (hardware/src/hdl/plain_data.sv): the byte-level crossbar
    between StripLevels, the DictionaryBody, the PlainStringDecoder and the value
    output path. conf is a bare type_t and picks the route:

      german  in_from_stripped    -> out_to_str_decoder
              in_from_str_decoder -> out_values
      fixed   in_from_stripped    -> out_values

    The router no longer inspects the page type, so it is configured once per
    PLAIN page only. DICT and HYBRID pages carry no data through it and must not
    be configured: their select would never be retired and would desync the
    demultiplexer from the multiplexer for every page that follows.

    The router never touches the bytes, so every expected output is its input
    bytes unchanged. Page boundaries are the stream `last` beats: one conf per
    last-terminated transfer on each active stream.

    vfpga top wiring:
      recv[0] -> in_from_stripped
      recv[1] -> in_from_str_decoder
      out_values -> send[0]
      out_to_str_decoder -> send[1]
    """

    alternative_vfpga_top_file = "vfpga_tops/plain_router_test.sv"
    debug_mode = True

    def _run_pages(self, pages: list[dict]):
        for page in pages:
            if page["page_type"] == PAGE_TYPE_PLAIN:
                self.write_register(fpga_register.vFPGARegister(
                    REG_CONF, bytearray(page["typ"].to_bytes(8, 'little'))))

            for key, stream in (("stripped", IN_STRIPPED),
                                ("from_str_decoder", IN_STR_DECODER)):
                if key in page:
                    self.set_stream_input(stream, page[key])

            for key, stream in (("values", OUT_VALUES),
                                ("to_str_decoder", OUT_STR_DECODER)):
                if key in page:
                    self.set_expected_output(stream, page[key])

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- PLAIN / fixed: stripped -> out_values --------------------------------
    def test_plain_fixed_partial_beat(self):
        rng = Random(1)
        self._run_pages([plain_fixed(INT32_T, _rand(rng, 20))])

    def test_plain_fixed_exact_beat(self):
        rng = Random(2)
        self._run_pages([plain_fixed(BYTE_T, _rand(rng, BEAT_SIZE))])

    def test_plain_fixed_multi_beat_partial_final(self):
        rng = Random(3)
        self._run_pages([plain_fixed(INT64_T, _rand(rng, 3 * BEAT_SIZE + 17))])

    def test_plain_fixed_multi_beat_exact(self):
        rng = Random(4)
        self._run_pages([plain_fixed(DOUBLE_T, _rand(rng, 4 * BEAT_SIZE))])

    # -- PLAIN / german: stripped -> decoder, decoded -> out_values -----------
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
        # The trailing plain page is what the router actually sees; the dict and
        # hybrid pages ahead of it must leave its config queues untouched.
        rng = Random(16)
        self._run_pages([
            dict_fixed(INT64_T),
            hybrid(INT64_T, _rand(rng, BEAT_SIZE)),
            hybrid(INT64_T, _rand(rng, 40)),
            plain_fixed(INT64_T, _rand(rng, 3 * BEAT_SIZE)),
        ])

    def test_string_dict_then_hybrid_pages(self):
        rng = Random(17)
        self._run_pages([
            dict_string(_rand(rng, 2 * BEAT_SIZE), _rand(rng, BEAT_SIZE)),
            hybrid(GERMAN_STR_T, _rand(rng, BEAT_SIZE + 32)),
            hybrid(GERMAN_STR_T, _rand(rng, 16)),
            plain_string(_rand(rng, BEAT_SIZE + 24), _rand(rng, 48)),
        ])

    def test_non_plain_pages_between_routed_pages(self):
        """A dict or hybrid page between two plain pages of different types must
        not shift the routing: the second plain page picks up its own config."""
        rng = Random(21)
        self._run_pages([
            plain_string(_rand(rng, 96), _rand(rng, 40)),
            dict_fixed(INT32_T),
            hybrid(INT32_T, _rand(rng, BEAT_SIZE)),
            plain_fixed(INT32_T, _rand(rng, BEAT_SIZE + 12)),
            hybrid(GERMAN_STR_T, _rand(rng, 32)),
            plain_string(_rand(rng, 2 * BEAT_SIZE), _rand(rng, BEAT_SIZE + 8)),
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
            # in_from_dict_body -> out_to_str_decoder, in_from_str_decoder -> out_to_dict_body
            dict_string(_rand(rng, 64), _rand(rng, 24)),
            # none
            hybrid(GERMAN_STR_T, _rand(rng, 128)),
            hybrid(GERMAN_STR_T, _rand(rng, 192)),
            hybrid(GERMAN_STR_T, _rand(rng, 207)),
            hybrid(GERMAN_STR_T, _rand(rng, 15)),
            # in_from_stripped -> out_to_str_decoder, in_from_str_decoder -> out_values
            plain_string(_rand(rng, 323), _rand(rng, 278)),
            plain_string(_rand(rng, 243), _rand(rng, 189)),
            plain_string(_rand(rng, 123), _rand(rng, 64)),
            # none
            dict_fixed(DOUBLE_T),
            # none
            hybrid(DOUBLE_T, _rand(rng, 2 * BEAT_SIZE)),
            hybrid(DOUBLE_T, _rand(rng, 345)),
            hybrid(DOUBLE_T, _rand(rng, 312)),
            hybrid(DOUBLE_T, _rand(rng, 123)),
            # in_from_stripped ->  out_values
            plain_fixed(DOUBLE_T, _rand(rng, 124)),
        ])
