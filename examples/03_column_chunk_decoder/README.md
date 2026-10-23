# ColumnChunkDecoder Benchmark

Throughput benchmark and correctness check for the full ParCore design
([hardware/src/vfpga_top.svh](../../hardware/src/vfpga_top.svh)) on real Parquet files.

Every flat column of the given files that is of a type ParCore supports
(`parcore::metadata::is_libstf_type`) or a string column (`BYTE_ARRAY`,
`parcore::metadata::is_string_type`) is decoded across all row groups. The column chunks of one
column are loaded into memory before it is decoded and freed afterwards. The
column chunks are distributed round-robin over the `ColumnChunkDecoder`s with several chunks in
flight per decoder, and one CSV row is printed per column. With `--verify`, every column chunk is
first decoded once and compared against the physical values (e.g., the unscaled integers of
decimals) that Arrow's Parquet reader decodes from the same chunk. Boolean columns are bit-packed
in Parquet but output as bytes by ParCore, so they are skipped and not counted in the `verified`
column.

String columns are decoded into 16 byte records laid out like DuckDB's `string_t` on the decoder's
values stream: the length, then strings of up to 12 bytes inline, longer ones as their first 4 bytes
and a pointer. Only the strings longer than 12 bytes are written to the decoder's heap stream, back
to back. The pointers are the heap address the column chunk is configured with plus the offset of
the string in the heap. This example lets the `OutputBufferManager` place the heap, so it configures
address 0, which makes the pointers offsets into the heap. Software that provides the heap buffer
itself passes its address and gets pointers it can hand on without copying. `--verify` checks every
record and the heap against the strings Arrow decodes, and `out_bytes` includes the heap.

The last columns of the CSV are the decoders' input and output stream profiling counters, summed
over the decoders and the timed repetitions: the cycles with a handshake (`*_beats`), without valid
data (`*_starved`) and with valid data that was not taken (`*_stalled`). Stalled input cycles mean
that the decoder is the bottleneck, starved ones that the input does not arrive fast enough.

## Synthesizing the hardware

```bash
scripts/synthesize.sh column-chunk-decoder
```

## Building the software

The example needs Arrow and Parquet (`scripts/install_arrow.sh` installs them into `~/opt`):

```bash
cmake -S . -B build -DCMAKE_PREFIX_PATH=$HOME/opt && cmake --build build --target column_chunk_decoder
```

For simulations, add `-DEN_SIMULATION=ON` to the first cmake call.

## Running the example

```bash
build/column_chunk_decoder [OPTIONS] FILE...
```

| Option | Description |
| --- | --- |
| `-D, --decoders N` | Decoders to use, 0 for all of the design (default: 0) |
| `-r, --reps N` | Repetitions per column (default: 10) |
| `-d, --depth N` | Column chunks kept in flight per decoder, at most the config FIFO capacity of the design minus one (default: 4) |
| `-c, --columns C` | Comma-separated names of the columns to decode (default: all) |
| `-g, --row-groups F[:N]` | Decode only N row groups starting at row group F (default: all) |
| `-v, --verify` | Compare every column chunk against Arrow's Parquet reader first |

For simulations, set up a simulation project of the full design. `hardware/build-sim` does not work,
as the unit tests replace its vFPGA top:

```bash
cmake -S hardware -B hardware/build-full-sim && cmake --build hardware/build-full-sim --target sim
```

Then add `COYOTE_SIM_DIR="/<path-to-this-repo>/hardware/build-full-sim"` before executing the example
software. It is recommended to use small files and a single repetition (`-r 1`).
