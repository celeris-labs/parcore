// Decodes a parquet file on the FPGA and checks the result against Arrow.
//
// Unlike readfile, this example understands BYTE_ARRAY columns: the decoder
// emits 16-byte german_str_t records on the values stream and the raw string
// bytes on a second "heap" stream, and the two have to be recombined to get
// back the actual strings. Everything here goes through ColumnChunkDecoder
// directly rather than the Reader hierarchy, so the two-stream handling stays
// visible instead of being buried behind next_column_chunk().

#include <atomic>
#include <boost/program_options.hpp>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <arrow/array.h>
#include <arrow/io/file.h>
#include <coyote/cDefs.hpp>
#include <coyote/cThread.hpp>
#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/configuration.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/profiling.hpp>
#include <libstf/tlb_manager.hpp>
#include <parcore/column_chunk_decoder.hpp>
#include <parcore/cpu/cpu.hpp>
#include <parcore/metadata/metadata.hpp>
#include <parcore/metadata/utils.hpp>

using libstf::Profiler;

#define DEFAULT_VFPGA_ID 0

namespace po = boost::program_options;

const std::string separator = std::string(80, '-');

// A german_str_t is 16 bytes, serialised LSB-first:
//   [0:4)  length, little endian
//   [4:8)  the string's first 4 bytes (zero padded)
//   [8:16) bytes 4..11 inline if length <= 12, otherwise an 8-byte LE heap address
static constexpr size_t GERMAN_STR_BYTES = 16;
static constexpr uint32_t GERMAN_STR_INLINE_LEN = 12;

std::shared_ptr<libstf::OutputBufferManager> obm;

static void handle_fpga_interrupt(int value) { obm->handle_fpga_interrupt(value); }

// ---------------------------------------------------------------------------
// Output collection
// ---------------------------------------------------------------------------

static std::vector<uint8_t> drain(const std::shared_ptr<libstf::OutputHandle> &handle,
                                  libstf::stream_t stream, size_t *num_buffers = nullptr) {
  std::vector<uint8_t> out;
  size_t count = 0;
  while (handle->stream_has_more_output(stream)) {
    auto buf = handle->get_next_stream_output(stream);
    if (buf == nullptr)
      break;
    auto ptr = static_cast<const uint8_t *>(buf->ptr);
    out.insert(out.end(), ptr, ptr + buf->size);
    count += 1;
  }
  if (num_buffers != nullptr)
    *num_buffers = count;
  return out;
}

// ---------------------------------------------------------------------------
// German string reconstruction
// ---------------------------------------------------------------------------

// Rebuilds the strings from the decoder's records plus the heap. `heap_base` is
// the device address the heap was written to; long-string records point into it.
static std::vector<std::string> rebuild_strings(const std::vector<uint8_t> &records,
                                                const std::vector<uint8_t> &heap,
                                                uint64_t heap_base) {
  if (records.size() % GERMAN_STR_BYTES != 0)
    throw std::runtime_error("values stream is not a whole number of german_str_t records (" +
                             std::to_string(records.size()) + " bytes)");

  std::vector<std::string> strings;
  strings.reserve(records.size() / GERMAN_STR_BYTES);

  for (size_t off = 0; off < records.size(); off += GERMAN_STR_BYTES) {
    const uint8_t *rec = records.data() + off;

    uint32_t length;
    std::memcpy(&length, rec, sizeof(length));

    if (length <= GERMAN_STR_INLINE_LEN) {
      // The whole string sits in the record, starting right after the length.
      strings.emplace_back(reinterpret_cast<const char *>(rec + 4), length);
      continue;
    }

    uint64_t address;
    std::memcpy(&address, rec + 8, sizeof(address));
    if (address < heap_base)
      throw std::runtime_error("string address " + std::to_string(address) +
                               " is below the heap base " + std::to_string(heap_base));

    uint64_t offset = address - heap_base;
    if (offset + length > heap.size())
      throw std::runtime_error("string at heap offset " + std::to_string(offset) + " of length " +
                               std::to_string(length) + " runs past the " +
                               std::to_string(heap.size()) + " byte heap");

    strings.emplace_back(reinterpret_cast<const char *>(heap.data() + offset), length);
  }

  return strings;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

static bool compare_bytes(const std::vector<uint8_t> &cpu, const std::vector<uint8_t> &fpga) {
  if (cpu.size() != fpga.size()) {
    std::cout << "\tSIZE MISMATCH: cpu produced " << cpu.size() << " bytes, fpga produced "
              << fpga.size() << std::endl;
    return false;
  }
  for (size_t i = 0; i < cpu.size(); ++i) {
    if (cpu[i] != fpga[i]) {
      std::cout << "\tMISMATCH at byte " << i << ": expected " << static_cast<int>(cpu[i])
                << ", got " << static_cast<int>(fpga[i]) << std::endl;
      return false;
    }
  }
  std::cout << "\tOK: " << cpu.size() << " bytes match" << std::endl;
  return true;
}

static bool compare_strings(const std::shared_ptr<arrow::ChunkedArray> &expected,
                            const std::vector<std::string> &actual) {
  if (static_cast<size_t>(expected->length()) != actual.size()) {
    std::cout << "\tCOUNT MISMATCH: cpu produced " << expected->length() << " strings, fpga "
              << actual.size() << std::endl;
    return false;
  }

  size_t i = 0;
  for (const auto &cc : expected->chunks()) {
    if (cc->type_id() != arrow::Type::STRING && cc->type_id() != arrow::Type::BINARY)
      throw std::runtime_error("expected a STRING/BINARY array from Arrow, got " +
                               cc->type()->ToString());
    auto arr = std::static_pointer_cast<arrow::BinaryArray>(cc);
    for (int64_t k = 0; k < arr->length(); ++k, ++i) {
      auto want = arr->GetView(k);
      if (want.size() != actual[i].size() ||
          std::memcmp(want.data(), actual[i].data(), want.size()) != 0) {
        std::cout << "\tMISMATCH at string " << i << ": expected \"" << want << "\", got \""
                  << actual[i] << "\"" << std::endl;
        return false;
      }
    }
  }
  std::cout << "\tOK: " << actual.size() << " strings match" << std::endl;
  return true;
}

// ---------------------------------------------------------------------------

int main(int argc, char *argv[]) {
  Profiler::init();

  std::string parquet_file;
  size_t start_group, end_group;
  long column = -1;
  bool skip_verify = false;

  po::options_description runtime_options(
      "Decode a parquet file on the FPGA and verify it against Arrow");
  runtime_options.add_options()                                                       //
      ("help,h", "Show this message")                                                 //
      ("file,f", po::value<std::string>(&parquet_file)->required(),                   //
       "Path to the parquet file to decode")                                          //
      ("start,s", po::value<size_t>(&start_group)->default_value(0),                  //
       "First row group to process")                                                  //
      ("end,e", po::value<size_t>(&end_group)->default_value(0),                      //
       "Last row group to process (exclusive). 0 means all")                          //
      ("column,j", po::value<long>(&column)->default_value(-1),                       //
       "Only decode this column index. Negative means all columns")                   //
      ("no-verify", po::bool_switch(&skip_verify),                                    //
       "Skip the Arrow reference decode and only run the FPGA");

  po::variables_map command_line_arguments;
  po::store(po::parse_command_line(argc, argv, runtime_options), command_line_arguments);
  if (command_line_arguments.count("help")) {
    std::cout << runtime_options << std::endl;
    return EXIT_SUCCESS;
  }
  po::notify(command_line_arguments);

  Profiler::start();

  auto meta = parcore::metadata::from_file(parquet_file);
  if (end_group == 0)
    end_group = meta.groups.size();
  if (start_group > meta.groups.size() || start_group > end_group ||
      end_group > meta.groups.size())
    throw std::runtime_error("invalid start/end bounds");

  auto cthread =
      std::make_shared<coyote::cThread>(DEFAULT_VFPGA_ID, getpid(), 0, &handle_fpga_interrupt);
#ifdef ENABLE_SIMULATION
  auto pool = std::make_shared<libstf::SimpleMemoryPool>();
#else
  auto pool = std::make_shared<libstf::HugePageMemoryPool>();
#endif
  auto tlb = std::make_shared<libstf::TLBManager>(cthread, pool);
#ifndef ENABLE_SIMULATION
  tlb->ensure_tlb_mapping(pool->initial_address(), pool->total_capacity());
#endif

  auto maybe_file = arrow::io::ReadableFile::Open(parquet_file);
  if (!maybe_file.ok())
    throw std::runtime_error(maybe_file.status().ToString());
  std::shared_ptr<arrow::io::ReadableFile> file = *maybe_file;

  libstf::GlobalConfig global_config(cthread);
  auto mem_config = global_config.get_config<libstf::MemConfig>();
  auto column_chunk_config = global_config.get_config<parcore::ColumnChunkDecoderConfig>();

#ifdef ENABLE_SIMULATION
  // SimpleMemoryPool is a bump allocator over a fixed 1 GiB arena whose free()
  // is a no-op, so every buffer the manager retires is gone for good and the
  // run dies once the arena is used up -- at 2 MiB a buffer that was ~390
  // column chunks. 512 KiB still covers any single chunk these files produce
  // and gives the arena four times the reach.
  size_t obm_buffers = 2, obm_capacity = 1 << 19 /* 512KiB */;
#else
  size_t obm_buffers = 40, obm_capacity = 1 << 24 /* 16MiB */;
#endif
  // Overridable so the buffer budget can be swept without a rebuild -- the same
  // sweep is what distinguishes a per-stream depth from a shared one.
  if (const char *e = std::getenv("PARCORE_OBM_BUFFERS"))
    obm_buffers = std::stoul(e);
  if (const char *e = std::getenv("PARCORE_OBM_CAPACITY"))
    obm_capacity = std::stoul(e);

  obm = std::make_shared<libstf::OutputBufferManager>(
      cthread, mem_config, pool, tlb, ~libstf::stream_mask_t(0), obm_buffers, obm_capacity);
  obm->flush_buffers();
  std::cout << "flushed buffers" << std::endl;

  // maximum_num_enqueued_buffers() is a hardware register. If it is a budget
  // shared across streams rather than a per-stream depth, then enqueueing
  // num_buffers_to_enqueue on each of num_streams overruns it and the surplus
  // goes nowhere -- which would starve a stream of somewhere to write after a
  // fixed number of buffers, regardless of the data.
  std::cout << "buffer budget: num_streams=" << obm->num_streams()
            << " num_buffers_to_enqueue=" << obm->num_buffers_to_enqueue() << " (per stream)"
            << " hardware_max=" << mem_config->maximum_num_enqueued_buffers()
            << " total_requested=" << obm->num_streams() * obm->num_buffers_to_enqueue()
            << std::endl;
  if (obm->num_streams() * obm->num_buffers_to_enqueue() >
      mem_config->maximum_num_enqueued_buffers()) {
    std::cout << "  *** total_requested exceeds hardware_max ***" << std::endl;
  }

  auto decoder =
      std::make_shared<parcore::ColumnChunkDecoder>(cthread, tlb, obm, column_chunk_config, 0);

  size_t decoded = 0, skipped = 0, failed = 0;

  // -- stall watchdog ------------------------------------------------------
  // The StreamProfilers on the decoder's in and out ports are not behind
  // `ifdef DEBUG, so their counters are readable over the register interface
  // even in a build without ILAs. They are free running, so sampling them twice
  // while wedged says which side is blocked:
  //
  //   in.stalled  climbing -> in.valid && !in.ready   : decoder wedged inside
  //   in.starved  climbing -> in.ready && !in.valid   : decoder waiting on input
  //   out.stalled climbing -> out.valid && !out.ready : writer not taking values
  //   out.starved climbing -> decoder producing nothing
  //
  // Note there is no profiler on heap_out, so a blocked heap path shows up as
  // in.stalled with out.starved rather than directly.
  std::atomic<bool> wd_stop{false};
  std::atomic<size_t> wd_chunk{0};
  std::atomic<long long> wd_started_ms{0};
  const long long wd_timeout_ms =
      std::getenv("PARCORE_STALL_TIMEOUT_S")
          ? std::stoll(std::getenv("PARCORE_STALL_TIMEOUT_S")) * 1000
          : 10000;

  auto now_ms = [] {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
  };

  auto dump_profile = [&](const char *tag) {
    try {
      auto p = column_chunk_config->read_profile(0);
      std::cerr << "[stall] " << tag << " chunk=" << wd_chunk.load()
                << "  in: hs=" << p.in.handshakes_cycles << " starved=" << p.in.starved_cycles
                << " stalled=" << p.in.stalled_cycles << " idle=" << p.in.idle_cycles
                << " | out: hs=" << p.out.handshakes_cycles << " starved=" << p.out.starved_cycles
                << " stalled=" << p.out.stalled_cycles << " idle=" << p.out.idle_cycles
                << std::endl;
    } catch (const std::exception &e) {
      // A diagnostic must never take the run down with it.
      std::cerr << "[stall] " << tag << " profile read failed: " << e.what() << std::endl;
    }
  };

  std::thread watchdog([&] {
    bool reported = false;
    try {
    while (!wd_stop.load()) {
      std::this_thread::sleep_for(std::chrono::seconds(5));
      auto started = wd_started_ms.load();
      if (started == 0 || wd_stop.load())
        continue;
      if (now_ms() - started < wd_timeout_ms) {
        reported = false;
        continue;
      }
      if (reported)
        continue;
      reported = true;
      std::cerr << "[stall] chunk " << wd_chunk.load() << " has been in flight for "
                << (now_ms() - started) / 1000 << "s" << std::endl;
      for (libstf::stream_t s = 0; s < obm->num_streams(); ++s) {
        auto st = obm->stats(s);
        std::cerr << "[stall] stream " << static_cast<int>(s)
                  << " outstanding=" << st.enqueued_now << " enqueued_total=" << st.enqueued_total
                  << " interrupts=" << st.interrupts << " bytes=" << st.bytes_written << std::endl;
      }
      // Two samples three seconds apart: whichever counter moved is the blockage.
      dump_profile("sample1");
      std::this_thread::sleep_for(std::chrono::seconds(3));
      dump_profile("sample2");

      // The heap buffer the FPGA is currently writing into. If the chunk's heap
      // bytes are already here then the data arrived and only the completion
      // (last) went missing -- the writer is sitting on a partially filled
      // buffer that will never fill, so no interrupt is ever raised. If it is
      // still zeroed, the heap was never produced at all. Those are different
      // bugs and this tells them apart.
      try {
        const auto *p = static_cast<const unsigned char *>(obm->next_buffer_address(1));
        const size_t cap = obm->buffer_capacity();

        // Walk back to the last non-zero byte: that is how far the FPGA got.
        // Coarse by 4 KiB, then refine. A freshly mmap'd buffer is zeroed, but a
        // recycled one may hold an older chunk's bytes, so compare the boundary
        // against the chunk's expected heap size rather than trusting it alone.
        size_t page = cap;
        while (page > 0) {
          page -= 4096;
          bool any = false;
          for (size_t k = 0; k < 4096 && !any; ++k)
            any = p[page + k] != 0;
          if (any)
            break;
        }
        size_t last_nz = page;
        for (size_t k = 0; k < 4096; ++k)
          if (p[page + k] != 0)
            last_nz = page + k;

        std::cerr << "[stall] heapbuf capacity=" << cap << " last_nonzero_byte=" << last_nz
                  << " (" << (last_nz * 100.0 / cap) << "% of buffer)" << std::endl;

        for (size_t off : {size_t(0), last_nz > 64 ? last_nz - 47 : size_t(0)}) {
          std::cerr << "[stall] heapbuf+" << off << ":";
          for (size_t k = 0; k < 48 && off + k < cap; ++k)
            std::cerr << " " << std::hex << std::setw(2) << std::setfill('0')
                      << static_cast<unsigned>(p[off + k]);
          std::cerr << std::dec << "  |";
          for (size_t k = 0; k < 48 && off + k < cap; ++k) {
            unsigned char c = p[off + k];
            std::cerr << (c >= 32 && c < 127 ? static_cast<char>(c) : '.');
          }
          std::cerr << "|" << std::endl;
        }
      } catch (const std::exception &e) {
        std::cerr << "[stall] heap buffer peek failed: " << e.what() << std::endl;
      }
    }
    } catch (const std::exception &e) {
      std::cerr << "[stall] watchdog stopped: " << e.what() << std::endl;
    }
  });

  for (size_t i = start_group; i < end_group; ++i) {
    const auto &group = meta.groups[i];
    for (size_t j = 0; j < group.chunks.size(); ++j) {
      if (column >= 0 && static_cast<size_t>(column) != j)
        continue;
      const auto &chunk = group.chunks[j];

      const bool is_string = parcore::metadata::is_string_type(chunk.type);
      if (!is_string && !parcore::metadata::is_libstf_type(chunk.type)) {
        std::cout << separator << "\nSkipping column chunk " << i << ":" << j << " (type "
                  << chunk.type << " is not supported)" << std::endl;
        skipped += 1;
        continue;
      }

      auto typ = parcore::metadata::to_libstf_type(chunk.type);

      std::cout << separator << std::endl;
      std::cout << "Decoding column chunk " << i << ":" << j;
      if (j < meta.column_names.size())
        std::cout << " (" << meta.column_names[j] << ")";
      std::cout << std::endl;
      std::cout << "\tcompression: " << chunk.compression << ", type: " << chunk.type
                << ", values: " << chunk.num_values << std::endl;
      std::cout << "\toffset: " << chunk.offset << ", size: " << chunk.total_compressed_size
                << std::endl;

      // Buffer bookkeeping, printed *before* the transfer so the last line in
      // the log describes the state the FPGA was handed when it stopped. On
      // stderr and unbuffered so nothing is lost if the process is killed.
      for (libstf::stream_t s = 0; s < obm->num_streams(); ++s) {
        auto st = obm->stats(s);
        std::cerr << "[bufs] chunk=" << decoded << " rg=" << i << " col=" << j << " stream=" << s
                  << " outstanding=" << st.enqueued_now << "/" << obm->num_buffers_to_enqueue()
                  << " enqueued_total=" << st.enqueued_total << " interrupts=" << st.interrupts
                  << " bytes=" << st.bytes_written << std::endl;
      }

      // -- read the raw column chunk into device-visible memory ------------
      void *raw_ptr;
      auto alloc = pool->allocate(chunk.total_compressed_size, &raw_ptr);
      if (!alloc.ok())
        throw std::runtime_error("could not allocate chunk buffer: " + alloc.message());
      auto raw = libstf::make_buffer(pool, raw_ptr, chunk.total_compressed_size,
                                     chunk.total_compressed_size);

      auto seek = file->Seek(chunk.offset);
      if (!seek.ok())
        throw std::runtime_error("seek failed: " + seek.message());
      auto read = file->Read(chunk.total_compressed_size, raw->ptr);
      if (!read.ok())
        throw std::runtime_error("read failed: " + read.status().message());

      // -- FPGA -------------------------------------------------------------
      auto fpga_start = std::chrono::high_resolution_clock::now();
      wd_chunk.store(decoded);
      wd_started_ms.store(now_ms());

      // The Handle holds the decoder's mutex for its whole lifetime, and
      // std::move(*handle).done() does not destroy it - the unique_ptr still
      // owns it. Without this scope the Handle would outlive the decode and
      // deadlock against finished_decoding_column_chunk() below.
      uint64_t heap_base = 0;
      std::shared_ptr<libstf::OutputHandle> output;
      {
        auto handle = decoder->decode_column_chunk(chunk);
        // The heap base has to be known before the chunk config is written, so
        // decode_column_chunk resolves it while acquiring the output buffers.
        heap_base = handle->string_heap_address();
        handle->add_chunk(raw);
        output = std::move(*handle).done();
      }

      size_t values_buffers = 0;
      auto values = drain(output, decoder->values_stream(), &values_buffers);
      std::vector<uint8_t> heap;
      if (is_string) {
        size_t heap_buffers = 0;
        heap = drain(output, decoder->heap_stream(), &heap_buffers);
        if (heap_buffers > 1)
          throw std::runtime_error(
              "the string heap was split across " + std::to_string(heap_buffers) +
              " buffers; the decoder addresses it linearly from a single base, so the "
              "output buffer capacity must exceed the chunk's string bytes");
      }

      auto fpga_end = std::chrono::high_resolution_clock::now();
      auto fpga_us =
          std::chrono::duration_cast<std::chrono::microseconds>(fpga_end - fpga_start).count();

      decoder->finished_decoding_column_chunk(chunk);

      std::cout << "\tfpga: " << fpga_us << "us, " << values.size() << " value bytes";
      if (is_string)
        std::cout << ", " << heap.size() << " heap bytes";
      std::cout << std::endl;

      decoded += 1;
      if (skip_verify)
        continue;

      // -- CPU reference ----------------------------------------------------
      auto cpu_start = std::chrono::high_resolution_clock::now();
      auto cpu_data = parcore::cpu::read_column_chunk(file, i, j);
      auto cpu_end = std::chrono::high_resolution_clock::now();
      std::cout << "\tcpu:  "
                << std::chrono::duration_cast<std::chrono::microseconds>(cpu_end - cpu_start)
                       .count()
                << "us" << std::endl;

      bool ok;
      if (is_string) {
        ok = compare_strings(cpu_data, rebuild_strings(values, heap, heap_base));
      } else {
        std::vector<uint8_t> expected;
        for (const auto &cc : cpu_data->chunks()) {
          if (cc->type_id() == arrow::Type::DECIMAL128) {
            // Parquet stores these with an INT64 physical type and the decoder
            // emits exactly that, but Arrow widens them to 128 bits on read.
            // The buffer is little endian, so the decoder's value is the low
            // half of each 16-byte entry.
            auto arr = std::static_pointer_cast<arrow::FixedSizeBinaryArray>(cc);
            for (int64_t k = 0; k < arr->length(); ++k) {
              const uint8_t *v = arr->GetValue(k);
              expected.insert(expected.end(), v, v + libstf::size_of(typ));
            }
            continue;
          }
          auto arr = std::static_pointer_cast<arrow::PrimitiveArray>(cc);
          const uint8_t *data = arr->data()->GetValues<uint8_t>(1);
          expected.insert(expected.end(), data, data + arr->length() * libstf::size_of(typ));
        }
        ok = compare_bytes(expected, values);
      }
      if (!ok)
        failed += 1;
    }
  }

  wd_stop.store(true);
  watchdog.join();

  std::cout << separator << std::endl;
  std::cout << decoded << " column chunk(s) decoded, " << skipped << " skipped, " << failed
            << " mismatched" << std::endl;

  Profiler::flush();
  return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
