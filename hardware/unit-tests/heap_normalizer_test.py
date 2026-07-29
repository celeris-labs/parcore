from random import Random

from coyote_test import fpga_test_case, fpga_register

REG_CONF = 3

BEAT_SIZE = 64


def _rand(rng: Random, n: int) -> bytearray:
    return bytearray(rng.randrange(256) for _ in range(n))


def _conf(generates_heap: int, last_page: int) -> int:
    return (generates_heap << 1) | last_page


class HeapNormalizerTestCase(fpga_test_case.FPGATestCase):
    """
    Tests HeapNormalizer: builds one packed heap stream per chunk from a
    sequence of pages, driven by conf = {generates_heap, last_page}.

      - generates_heap: the page's raw bytes are appended to the heap.
      - last_page:      the page is the chunk's final page (triggers the flush,
                        i.e. the single output `last`).

    Cross-page packing (see hardware/arch.md): a chunk's heap-page bytes are
    coalesced into one contiguous, fully-packed stream and emitted as a single
    last-terminated packet, so out == concat(heap-page bytes). Inter-page gaps
    (partial final beats) are closed by carrying residue across pages. A final
    page with no heap (generates_heap=0, last_page=1) injects an empty last beat
    that flushes the carried residue without adding bytes. Skip pages
    (generates_heap=0, last_page=0) consume conf and contribute nothing.

    Each heap page is driven as its own `in` transfer (per-page last); one conf
    is written per page. vfpga top wiring: recv[0] -> in, out -> send[0].
    """

    alternative_vfpga_top_file = "vfpga_tops/heap_normalizer_test.sv"
    debug_mode = True

    def _run(self, chunks: list[list[tuple[int, int, bytearray | None]]]):
        """chunks: list of chunks; each chunk is a list of
        (generates_heap, last_page, body) pages. Every chunk yields one packed
        output packet = concatenation of its heap-page bodies."""
        for pages in chunks:
            heap_bytes = bytearray()
            for generates_heap, last_page, body in pages:
                self.write_register(fpga_register.vFPGARegister(
                    REG_CONF, bytearray(_conf(generates_heap, last_page).to_bytes(4, 'little'))))
                if generates_heap:
                    self.set_stream_input(0, body)
                    heap_bytes += body
            self.set_expected_output(0, heap_bytes)

        self.simulate_fpga()
        self.assert_simulation_output()

    # -- Single heap page: out == in ------------------------------------------
    def test_single_page_partial_beat(self):
        rng = Random(1)
        self._run([[(1, 1, _rand(rng, 40))]])

    def test_single_page_exact_beat(self):
        rng = Random(2)
        self._run([[(1, 1, _rand(rng, BEAT_SIZE))]])

    def test_single_page_multi_beat(self):
        rng = Random(3)
        self._run([[(1, 1, _rand(rng, 3 * BEAT_SIZE + 17))]])

    # -- Cross-page packing: pages coalesced into one packed stream -----------
    def test_two_heap_pages_pack(self):
        rng = Random(4)
        self._run([[(1, 0, _rand(rng, 40)), (1, 1, _rand(rng, 30))]])

    def test_three_heap_pages_pack(self):
        rng = Random(5)
        self._run([[(1, 0, _rand(rng, 20)),
                    (1, 0, _rand(rng, 70)),
                    (1, 1, _rand(rng, 33))]])

    def test_pages_beat_aligned(self):
        rng = Random(6)
        self._run([[(1, 0, _rand(rng, BEAT_SIZE)),
                    (1, 1, _rand(rng, 2 * BEAT_SIZE))]])

    # -- Skip pages (no heap, not last) are transparent -----------------------
    def test_skip_between_heap(self):
        rng = Random(7)
        self._run([[(1, 0, _rand(rng, 50)),
                    (0, 0, None),
                    (1, 1, _rand(rng, 25))]])

    def test_leading_skips(self):
        rng = Random(8)
        self._run([[(0, 0, None), (0, 0, None), (1, 1, _rand(rng, 45))]])

    # -- Dummy final page flushes carried residue -----------------------------
    def test_dummy_flush_after_heap(self):
        rng = Random(9)
        self._run([[(1, 0, _rand(rng, 40)),
                    (1, 0, _rand(rng, 30)),
                    (0, 1, None)]])

    # -- Back-to-back chunks --------------------------------------------------
    def test_back_to_back_chunks(self):
        rng = Random(10)
        self._run([
            [(1, 1, _rand(rng, 40))],
            [(1, 0, _rand(rng, 30)), (1, 1, _rand(rng, 90))],
        ])

    def test_mixed_chunks(self):
        rng = Random(11)
        self._run([
            [(1, 0, _rand(rng, 33)), (0, 0, None), (1, 1, _rand(rng, 60))],
            [(1, 0, _rand(rng, 128)), (0, 1, None)],
            [(1, 1, _rand(rng, 12))],
        ])

    # -- Config backlog -------------------------------------------------------
    #
    # Every case above uses pages of a few beats, so each conf is consumed well
    # before the next AXI-Lite write lands and the internal skid never holds
    # more than one entry. ColumnChunkDecoder is not so gentle: it enqueues one
    # conf per page on page_conf_fire, so a chunk's confs arrive back to back
    # and queue up while the first page is still draining through the decoder.
    #
    # These cases reproduce that by making the pages large enough (tens of
    # beats) that the FSM stays in PASSTHROUGH while the remaining confs pile
    # up behind it. A normaliser that reads the pre-skid conf instead of the
    # skidded one will latch an entry one or two ahead of the page it is
    # actually processing, and flush at the wrong page boundary.

    def test_large_pages_conf_backlog(self):
        rng = Random(12)
        self._run([[(1, 0, _rand(rng, 64 * BEAT_SIZE)),
                    (1, 0, _rand(rng, 64 * BEAT_SIZE)),
                    (1, 1, _rand(rng, 64 * BEAT_SIZE))]])

    def test_many_large_pages_conf_backlog(self):
        rng = Random(13)
        pages = [(1, 0, _rand(rng, 32 * BEAT_SIZE)) for _ in range(5)]
        pages.append((1, 1, _rand(rng, 32 * BEAT_SIZE)))
        self._run([pages])

    def test_large_pages_with_skip_and_flush(self):
        rng = Random(14)
        self._run([[(1, 0, _rand(rng, 48 * BEAT_SIZE)),
                    (0, 0, None),
                    (1, 0, _rand(rng, 48 * BEAT_SIZE)),
                    (0, 1, None)]])
