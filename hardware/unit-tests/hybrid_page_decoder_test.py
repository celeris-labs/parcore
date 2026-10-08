from coyote_test import fpga_test_case, fpga_stream, fpga_register
from os.path import dirname, realpath, join


def read_data(filename: str) -> bytearray:
    dir = dirname(realpath(__file__))
    with open(join(dir, 'data', filename), 'rb') as f:
        return bytearray(f.read())


def _decode_rle_bpe(body: bytes, bit_width: int, num_values: int) -> list[int]:
    """Reference decoder for a parquet RLE/bit-packing hybrid run sequence.

    `body` is the encoded payload *after* the bit_width byte. Used to derive the
    expected HybridPageDecoder output (dictionary ids) for a fixture page.
    """
    def read_varint(i: int) -> tuple[int, int]:
        shift = res = 0
        while True:
            byte = body[i]; i += 1
            res |= (byte & 0x7f) << shift
            if not (byte & 0x80):
                return res, i
            shift += 7

    byte_width = (bit_width + 7) // 8
    out: list[int] = []
    i = 0
    while len(out) < num_values:
        header, i = read_varint(i)
        if header & 1:  # bit-packed: (header >> 1) groups of 8 values
            count = (header >> 1) * 8
            nbytes = (count * bit_width + 7) // 8
            bits = int.from_bytes(body[i:i + nbytes], 'little'); i += nbytes
            mask = (1 << bit_width) - 1
            out.extend((bits >> (k * bit_width)) & mask for k in range(count))
        else:  # RLE run of (header >> 1) copies
            run = header >> 1
            val = int.from_bytes(body[i:i + byte_width], 'little'); i += byte_width
            out.extend([val] * run)
    return out[:num_values]


def custom_page_header(data: bytearray, size: int) -> bytearray:
    skip = int.from_bytes(data[:4], 'little')
    bit_width = data[skip+4]
    data = data[skip+5:]

    new_header = bytearray(size+5)
    new_header[0:4] = size.to_bytes(4, 'little')
    new_header[size+4] = bit_width.to_bytes(1, 'little')[0]
    return new_header + data


def strip_def_levels(data: bytearray) -> bytearray:
    """Turns an OPTIONAL-column page body into a REQUIRED-column one by dropping
    the 4-byte length prefix and the definition levels, leaving bit_width + runs."""
    skip = int.from_bytes(data[:4], 'little')
    return data[skip+4:]


# Reference outputs shared across cases.
_RLE_OUTPUT = [i - 10 for i in range(10, 20) for _ in range(i)]
_BPE_OUTPUT = list(range(10 - 10, 20 - 10)) * 15

# Ensure the `custom_page_header` function is correct
_rle_input = read_data('rle_data_rg0_col0_chunk_decompressed.bin')
assert custom_page_header(_rle_input, 13) == custom_page_header(custom_page_header(_rle_input, 75), 13)


class HybridPageDecoderTestCase(fpga_test_case.FPGATestCase):
    alternative_vfpga_top_file = "vfpga_tops/hybrid_page_decoder_test.sv"
    debug_mode = True
    # verbose_logging = True

    def run_pages(self, inputs: list[bytearray], outputs: list[list[int]],
                  is_required: list[bool] | None = None):
        """Drive the decoder with one or more pages and assert their outputs.

        Each page is streamed in and its num_values plus is_required flag
        (hybrid_page_conf_t: is_required at bit 32) is written to the per-page
        config register (offset 3); the expected outputs are asserted. Pages are
        of OPTIONAL columns (with definition levels) unless `is_required` says
        otherwise.
        """
        if is_required is None:
            is_required = [False] * len(outputs)
        for input in inputs:
            self.set_stream_input(0, input)
        for output, required in zip(outputs, is_required):
            self.set_expected_output(
                0, fpga_stream.Stream(fpga_stream.StreamType.SIGNED_INT_32, output)
            )
            conf = (int(required) << 32) | len(output)
            self.write_register(
                fpga_register.vFPGARegister(3, bytearray(conf.to_bytes(8, 'little')))
            )

        self.simulate_fpga()
        self.assert_simulation_output()

    def test_one_rle_page(self):
        self.run_pages(
            [read_data('rle_data_rg0_col0_chunk_decompressed.bin')],
            [_RLE_OUTPUT],
        )

    def test_custom_header_length(self):
        self.run_pages(
            [custom_page_header(read_data('rle_data_rg0_col0_chunk_decompressed.bin'), 64 + 15)],
            [_RLE_OUTPUT],
        )

    def test_tricky_header_length(self):
        self.run_pages(
            [custom_page_header(read_data('rle_data_rg0_col0_chunk_decompressed.bin'), 64 + 59)],
            [_RLE_OUTPUT],
        )

    def test_rle_and_bpe_page(self):
        self.run_pages(
            [read_data('rle_data_rg0_col0_chunk_decompressed.bin'),
             read_data('bpe_data_rg0_col0_chunk_decompressed.bin')],
            [_RLE_OUTPUT, _BPE_OUTPUT],
        )

    def test_bpe_page_drain(self):
        # back_to_back_bpe holds two BPE runs of 256 values (bit_width=8), but
        # we configure num_values=257 so the decode stops partway through the
        # second run. The RunDecoder emits those 257 values and resets at the 
        # first data beat of the second run without consuming the rest of the 
        # page, so the page's input `last` has not been seen when num_values 
        # is exhausted.
        self.run_pages(
            [read_data('back_to_back_bpe_chunk_decompressed.bin'),
             read_data('rle_data_rg0_col0_chunk_decompressed.bin')],
            [[i % 200 for i in range(256)] + [0], _RLE_OUTPUT],
        )

    def test_run_decoder_not_ready_drain(self):
        # Regression for a lock-up reproduced from lineitem's l_suppkey column
        # (RLE_DICTIONARY, bit_width=4, 6005 values). The page's last value lands
        # on the final input databeat, which also carries `last` plus trailing
        # padding bytes. The decode finishes (next_num_values == 0) on the exact
        # cycle that `last` beat is *present but not yet consumed*. The decoder
        # previously reset() on a merely-present `last` beat, stranding it (ST_IDLE
        # deasserts in.ready), which deadlocked the upstream pipeline. It must
        # instead drain that beat.
        fixture = read_data('lineitem_suppkey_hybrid_decompressed.bin')
        skip = int.from_bytes(fixture[:4], 'little')
        bit_width = fixture[skip + 4]
        body = bytes(fixture[skip + 5:])
        expected = _decode_rle_bpe(body, bit_width, 6005)
        self.run_pages(
            [fixture, read_data('rle_data_rg0_col0_chunk_decompressed.bin')],
            [expected, _RLE_OUTPUT],
        )

    def test_mixed_pages(self):
        self.run_pages(
            [read_data('rle_data_rg0_col0_chunk_decompressed.bin'),
             read_data('bpe_data_rg0_col0_chunk_decompressed.bin'),
             read_data('mixed_data_rg0_col0_chunk_decompressed.bin')],
            [_RLE_OUTPUT, _BPE_OUTPUT,
             [i - 10 for i in range(10, 20) for _ in range(i)] +
             list(range(128 - 118, 256 - 118)) * 2 +
             [i - 10 for i in range(10, 20) for _ in range(i)] +
             list(range(128 - 118, 256 - 118)) * 2],
        )

    def test_required_rle_page(self):
        # REQUIRED column: no definition levels, bit_width is the first byte.
        self.run_pages(
            [strip_def_levels(read_data('rle_data_rg0_col0_chunk_decompressed.bin'))],
            [_RLE_OUTPUT],
            is_required=[True],
        )

    def test_required_and_optional_pages(self):
        # Alternate REQUIRED and OPTIONAL pages to check the flag is taken per page.
        self.run_pages(
            [strip_def_levels(read_data('rle_data_rg0_col0_chunk_decompressed.bin')),
             read_data('bpe_data_rg0_col0_chunk_decompressed.bin'),
             strip_def_levels(read_data('bpe_data_rg0_col0_chunk_decompressed.bin')),
             read_data('rle_data_rg0_col0_chunk_decompressed.bin')],
            [_RLE_OUTPUT, _BPE_OUTPUT, _BPE_OUTPUT, _RLE_OUTPUT],
            is_required=[True, False, True, False],
        )
