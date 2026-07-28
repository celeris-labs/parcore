"""End-to-end tests for the shipping vFPGA top (hardware/src/vfpga_top.svh).

Unlike every other test in this directory these do not override the vfpga top, so
the design that actually gets synthesised is what runs: NUM_DECODERS
ColumnChunkDecoders fed from axis_host_recv[I], with their values and string heap
written back to host memory by PairedOutputWriter over FPGA-initiated transfers.
That covers the pieces no per-module test reaches - the register map produced by
GlobalConfig, MemConfig buffer handling, StreamWriter, the pair arbiter that
merges each decoder's two output streams onto one physical channel, and the
cross-channel request/completion arbitration.

Stream numbering follows PairedOutputWriter: decoder I writes its values on
logical stream 2I and its string heap on 2I + 1, both sharing physical channel I.
The heap stays completely silent for anything that is not a german string chunk,
so no transfer and no interrupt are expected on it there.
"""

from dataclasses import dataclass
from typing import Callable, Optional

from coyote_test import constants, fpga_register, fpga_stream

import libstf_utils.memory_manager as memory_manager

from libstf_utils.common import MAX_SUPPORTED_N_STREAMS
from libstf_utils.output_writer_test_case import OutputWriterTestCase

from column_chunk_decoder_test import (
    _ColumnChunk,
    _PLAIN_OUTPUT,
    _RLE_OUTPUT,
    _encode_strings,
    _german_records,
    _parquet_chunk,
    make_plain_data,
    make_string_data,
    make_tricky,
)

# FPGAOutputMemoryManager caps stream ids at MAX_NUMBER_STREAMS, which used to be
# both the number of physical AXI channels and the number of output streams.
# PairedOutputWriter puts two logical streams on each channel, so the real bound
# is the width of the interrupt's stream id field. Widening the guard is enough -
# nothing else in the manager assumes one stream per channel.
memory_manager.MAX_NUMBER_STREAMS = MAX_SUPPORTED_N_STREAMS

COLUMN_CHUNK_DECODER_CONFIG_ID = 0x5C19F934407065BD

# One decoder per physical AXI channel, mirroring N_STREAMS in the vfpga top.
NUM_DECODERS = constants.MAX_NUMBER_STREAMS


def values_stream(decoder: int) -> int:
    return 2 * decoder


def heap_stream(decoder: int) -> int:
    return 2 * decoder + 1


@dataclass
class _Job:
    """One column chunk to enqueue on one decoder, plus what it must produce.

    String chunks are finished off late: the addresses embedded in their
    german_str_t records point into the heap buffer the writer will fill, and that
    buffer is only handed out once the simulation is running. `finish` therefore
    takes the heap base address and returns the chunk together with its expected
    values. The raw heap bytes are independent of that address, so they are known
    up front and are what the allocation is registered against.
    """

    finish: Callable[[int], "tuple[_ColumnChunk, list]"]
    heap_bytes: Optional[bytearray] = None

    @property
    def is_string(self) -> bool:
        return self.heap_bytes is not None


def fixed_job(chunk: _ColumnChunk, values: list) -> _Job:
    return _Job(finish=lambda _heap_addr: (chunk, values))


def string_job(strings: "list[bytes]") -> _Job:
    def finish(heap_addr: int):
        return make_string_data(strings, heap_addr), _german_records(strings, heap_addr)

    return _Job(finish=finish, heap_bytes=_encode_strings(strings))


# Shorthands for the workloads used below.
def plain_job(items: list, stream_type=fpga_stream.StreamType.SIGNED_INT_64) -> _Job:
    return fixed_job(make_plain_data(items, stream_type), items)


def parquet_job(filename: str, values: list) -> _Job:
    return fixed_job(_parquet_chunk(filename), values)


class VFPGATopTestCase(OutputWriterTestCase):
    # Deliberately no alternative_vfpga_top_file: this drives hardware/src/vfpga_top.svh.
    debug_mode = True

    def _column_chunk_config_offset(self) -> int:
        assert self.global_config.has_config(COLUMN_CHUNK_DECODER_CONFIG_ID), (
            "The design does not expose a ColumnChunkDecoderConfig"
        )
        return self.global_config.get_config_bounds(COLUMN_CHUNK_DECODER_CONFIG_ID)[0]

    def _heap_base_address(self, decoder: int) -> int:
        """The buffer the heap writer of `decoder` will fill.

        Registering the heap expectation allocates it and pushes the handle to the
        FPGA, so this is only meaningful afterwards. Only the first allocation is
        used: the decoder addresses its heap linearly, so a payload spilling into a
        follow-up allocation would not be contiguous. Every workload here stays
        well inside one allocation.
        """
        allocations = self.memory_manager.allocations[heap_stream(decoder)]
        assert len(allocations) == 1, (
            f"Heap of decoder {decoder} spilled into {len(allocations)} allocations; "
            "the decoder assumes one contiguous heap buffer per column chunk."
        )
        return next(iter(allocations))

    def run_jobs(self, jobs: "dict[int, list[_Job]]"):
        """Drives each decoder with its list of chunks and asserts every output.

        At most one string chunk per decoder: the heap buffer for a second one is
        only handed out after the first one's completion interrupt, so its
        addresses cannot be predicted while building the expectation.
        """
        for decoder, decoder_jobs in jobs.items():
            assert decoder < NUM_DECODERS
            assert sum(job.is_string for job in decoder_jobs) <= 1, (
                f"decoder {decoder}: only one string chunk per run is supported"
            )

        # Configuration discovery does blocking register reads, so the simulation
        # has to be up before anything below can run.
        self.simulate_fpga_non_blocking()
        config_offset = self._column_chunk_config_offset()

        # Heap expectations first. They are address-independent, and registering
        # them is what allocates the buffers whose addresses the string chunks need.
        for decoder, decoder_jobs in jobs.items():
            for job in decoder_jobs:
                if job.is_string:
                    self.set_expected_output(
                        heap_stream(decoder),
                        fpga_stream.Stream(
                            fpga_stream.StreamType.UNSIGNED_INT_8, list(job.heap_bytes)
                        ),
                    )

        for decoder, decoder_jobs in jobs.items():
            for job in decoder_jobs:
                heap_addr = self._heap_base_address(decoder) if job.is_string else 0
                chunk, values = job.finish(heap_addr)

                # German records are compared as raw bytes; everything else at the
                # chunk's own width.
                if chunk.is_string:
                    expected = fpga_stream.Stream(
                        fpga_stream.StreamType.UNSIGNED_INT_8, values
                    )
                else:
                    expected = fpga_stream.Stream(chunk.stream_type, values)
                self.set_expected_output(values_stream(decoder), expected)

                self.write_register(
                    fpga_register.vFPGARegister(
                        config_offset + 2 * decoder, chunk._register()
                    )
                )
                # Only consumed for german strings - writing it otherwise would
                # desynchronise the two config FIFOs.
                if chunk.is_string:
                    self.write_register(
                        fpga_register.vFPGARegister(
                            config_offset + 2 * decoder + 1, chunk._heap_register()
                        )
                    )

                self.set_stream_input(decoder, chunk.chunk_bytes)

        self.finish_fpga_simulation()
        self.assert_simulation_output()

    # -- One decoder --------------------------------------------------------

    def test_single_decoder_plain(self):
        """The narrowest end-to-end path: one chunk, one writer, no heap."""
        self.run_jobs({0: [plain_job(_PLAIN_OUTPUT)]})

    def test_single_decoder_hybrid(self):
        """A dictionary-encoded parquet chunk, so the SNAPPY and hybrid paths run."""
        self.run_jobs({0: [parquet_job("rle_data.parquet", _RLE_OUTPUT)]})

    def test_single_decoder_strings(self):
        """Both writers of one pair active - the arbiter has to interleave them
        on channel 0 without either transfer overtaking its own request."""
        self.run_jobs({0: [string_job([b"alpha", b"b" * 30, b"gamma"])]})

    def test_single_decoder_all_inline_strings(self):
        """Every string fits inline, so the heap carries the raw page bytes but no
        record refers into it."""
        self.run_jobs({0: [string_job([b"a", b"bb", b"ccc", b"abcdefghijkl"])]})

    def test_single_decoder_sequential_chunks(self):
        """Several chunks back to back on one decoder: one acquire/transfer cycle
        per chunk on the same stream, each with its own buffer."""
        self.run_jobs(
            {
                0: [
                    plain_job(_PLAIN_OUTPUT),
                    parquet_job("rle_data.parquet", _RLE_OUTPUT),
                    plain_job(list(range(-100, 100)), fpga_stream.StreamType.SIGNED_INT_32),
                ]
            }
        )

    # -- Several decoders ---------------------------------------------------

    def test_all_decoders_plain(self):
        """One chunk per decoder at once: cross-channel request arbitration and
        completion demultiplexing, with only one writer live per channel."""
        self.run_jobs(
            {d: [plain_job(list(range(0, 200 + d)))] for d in range(NUM_DECODERS)}
        )

    def test_all_decoders_distinct_types(self):
        """Different widths in flight simultaneously, so a decoder cannot pick up
        another's type or byte scaling."""
        self.run_jobs(
            {
                0: [plain_job(list(range(0, 200)), fpga_stream.StreamType.UNSIGNED_INT_8)],
                1: [plain_job(list(range(-100, 100)), fpga_stream.StreamType.SIGNED_INT_32)],
                2: [plain_job(list(range(0, 150)), fpga_stream.StreamType.SIGNED_INT_64)],
                3: [plain_job([float(i) for i in range(0, 128)], fpga_stream.StreamType.FLOAT_32)],
            }
        )

    def test_all_decoders_strings(self):
        """All eight logical streams live at once - the heaviest load the pair
        arbiters and the shared request/completion paths can see."""
        self.run_jobs(
            {
                d: [string_job([bytes([0x41 + d]) * (10 + 5 * d), b"s%d" % d, b"z" * (20 + d)])]
                for d in range(NUM_DECODERS)
            }
        )

    def test_mixed_string_and_fixed_decoders(self):
        """Heap-bearing and heap-silent decoders side by side. The fixed decoders
        must raise no interrupt at all on their heap stream, so a spurious empty
        transfer there shows up as an unexpected completion."""
        self.run_jobs(
            {
                0: [string_job([b"mixed", b"m" * 25])],
                1: [plain_job(_PLAIN_OUTPUT)],
                2: [string_job([b"n" * 18, b"ok"])],
                3: [parquet_job("bpe_data.parquet", list(range(10, 20)) * 15)],
            }
        )

    def test_all_decoders_hybrid(self):
        """Four dictionary-encoded chunks in parallel, each with its own
        decompressor and dictionary."""
        mixed = ([i**8 for i in range(10, 20) for _ in range(i)] + list(range(128, 256)) * 2) * 2
        self.run_jobs(
            {
                0: [parquet_job("rle_data.parquet", _RLE_OUTPUT)],
                1: [parquet_job("bpe_data.parquet", list(range(10, 20)) * 15)],
                2: [parquet_job("mixed_data.parquet", mixed)],
                3: [parquet_job("big_bpe_data.parquet", list(range(10, 100)) * 5)],
            }
        )

    def test_dictionary_flush_across_decoders(self):
        """A chunk whose trailing plain page forces the dictionary flush, running
        against unrelated traffic on the other channels."""
        tricky = make_tricky("rle_data_rg0_col0", len(_RLE_OUTPUT), _PLAIN_OUTPUT, 2)
        self.run_jobs(
            {
                0: [fixed_job(tricky, _RLE_OUTPUT * 2 + _PLAIN_OUTPUT)],
                1: [string_job([b"c" * 40, b"dd"])],
                2: [plain_job(list(range(0, 100)))],
            }
        )

    # -- Output sizing ------------------------------------------------------

    def test_large_output_multiple_allocations(self):
        """Output larger than one allocation, so the writer takes several buffers
        and the manager sees non-last interrupts before the final one."""
        self.overwrite_memory_manager(allocation_size=1024, transfer_size=512)
        self.run_jobs({0: [plain_job(list(range(0, 1000)))]})

    def test_small_transfers(self):
        """One data beat per transfer, maximising request/completion traffic
        through the shared channel."""
        self.overwrite_memory_manager(allocation_size=512, transfer_size=64)
        self.run_jobs({0: [string_job([b"tiny", b"t" * 40])]})

    def overwrite_memory_manager(self, allocation_size: int, transfer_size: int):
        """Resizes the FPGA-initiated transfers, mirroring output_writer_test.py."""
        self.memory_manager = memory_manager.FPGAOutputMemoryManager(
            self.get_io_writer(),
            self.global_config,
            allocation_size,
            transfer_size,
            all_done_callback=self.memory_manager_all_done_callback_spawner,
        )
        self.set_system_verilog_defines(
            {"TRANSFER_SIZE_BYTES_OVERWRITE": str(transfer_size)}
        )
