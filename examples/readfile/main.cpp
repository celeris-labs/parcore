#include <boost/program_options.hpp>
#include <boost/program_options/value_semantic.hpp>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>

#include <arrow/array.h>
#include <coyote/cDefs.hpp>
#include <coyote/cThread.hpp>
#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/profiling.hpp>
#include <libstf/tlb_manager.hpp>
#include <parcore/column_chunk_decoder.hpp>
#include <parcore/cpu/cpu.hpp>
#include <parcore/file_reader.hpp>
#include <parcore/metadata/utils.hpp>

using libstf::Profiler;

// Default vFPGA to assign cThreads to; for designs with one region (vFPGA) this
// is the only possible value
#define DEFAULT_VFPGA_ID 0

const std::string separator = std::string(80, '-');

void diff(const void *d1, const void *d2, size_t size) {
  auto d1b = reinterpret_cast<const uint8_t *>(d1);
  auto d2b = reinterpret_cast<const uint8_t *>(d2);
  for (size_t i = 0; i < size; ++i) {
    if (d1b[i] != d2b[i]) {
      // Write buffers to files
      std::ofstream file_a("/tmp/a.bin", std::ios::binary);
      if (file_a) {
        file_a.write(reinterpret_cast<const char *>(d1b), size);
        file_a.close();
      }

      std::ofstream file_b("/tmp/b.bin", std::ios::binary);
      if (file_b) {
        file_b.write(reinterpret_cast<const char *>(d2b), size);
        file_b.close();
      }

      std::cout << "output mismatch at byte " + std::to_string(i) +
                       ", expected " + std::to_string(d1b[i]) +
                       " but instead got " + std::to_string(d2b[i]) +
                       ". Buffers written to /tmp/a.bin and /tmp/b.bin"
                << std::endl;
      return;
    }
  }
  std::cout << "\t" << size << " bytes match" << std::endl;
}

std::shared_ptr<libstf::OutputBufferManager> obm;

static void handle_fpga_interrupt(int value) {
  // The nullptr is a bit ugly but this function is private any can only be
  // called from the cthread, which means the private constructor was executed
  // and the context has been initialized!
  //
  // Note that we needed to implement the "handle_fpga_interrupt" function as a
  // static function due to a limitation in Coyote. The reason is that we need
  // to register a function pointer with Coyote to call when an interrupt is
  // triggered on the FPGA. However, Coyote only accepts a raw function pointer.
  // Raw function points can only be created in C++ from static methods. See
  // https://isocpp.org/wiki/faq/pointers-to-members#fnptr-vs-memfnptr-types In
  // particular, they cannot be created from what's called a
  // pointer-to-member-function: > NOTE: do not attempt to “cast” a poi
  // ter-to-member-function into a pointer-to-function; > the result is
  // undefined and probably disastrous.
  //   (From above link)
  obm->handle_fpga_interrupt(value);
}

int main(int argc, char *argv[]) {
  Profiler::init();

  std::string parquet_file;
  size_t start, end;

  boost::program_options::options_description runtime_options(
      "Parcore readfile");
  runtime_options.add_options()(
      "file,f", boost::program_options::value<std::string>(&parquet_file),
      "Path to the parquet file to parse")(
      "start,s",
      boost::program_options::value<size_t>(&start)->default_value(0),
      "The first row group to process")(
      "end,e", boost::program_options::value<size_t>(&end)->default_value(0),
      "The row group to stop before. 0 means to process all");
  boost::program_options::variables_map command_line_arguments;
  boost::program_options::store(
      boost::program_options::parse_command_line(argc, argv, runtime_options),
      command_line_arguments);
  boost::program_options::notify(command_line_arguments);

  Profiler::start();

  auto meta = parcore::metadata::from_file(parquet_file);
  if (end <= 0)
    end = meta.groups.size();
  if (start > meta.groups.size() || start > end || end > meta.groups.size())
    throw std::runtime_error("invalid start/end bounds");

  auto cthread = std::make_shared<coyote::cThread>(DEFAULT_VFPGA_ID, getpid(),
                                                   0, &handle_fpga_interrupt);
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
  if (!maybe_file.ok()) {
    throw std::runtime_error(maybe_file.status().ToString());
  }
  std::shared_ptr<arrow::io::ReadableFile> file = *maybe_file;

  libstf::GlobalConfig global_config(cthread);
  auto mem_config = global_config.get_config<libstf::MemConfig>();
  auto column_chunk_config =
      global_config.get_config<parcore::ColumnChunkDecoderConfig>();

#ifdef ENABLE_SIMULATION
  obm = std::make_shared<libstf::OutputBufferManager>(
      cthread, mem_config, pool, tlb, 2, 1 << 21 /* 2MiB */);
#else
  obm = std::make_shared<libstf::OutputBufferManager>(
      cthread, mem_config, pool, tlb, 40, 1 << 24 /* 16MiB */);
#endif
  obm->flush_buffers();
  std::cout << "flushed buffers" << std::endl;

  auto column_chunk_decoder = std::make_shared<parcore::ColumnChunkDecoder>(
      cthread, tlb, obm, column_chunk_config, 0);
  parcore::FileReader reader(column_chunk_decoder, pool, meta, file);

  for (size_t i = start; i < end; ++i) {
    auto group = meta.groups[i];
    for (size_t j = 0; j < group.chunks.size(); ++j) {
      auto chunk = group.chunks[j];

      if (!parcore::metadata::is_libstf_type(chunk.type))
        continue;

      auto typ = parcore::metadata::to_libstf_type(chunk.type);

      std::cout << separator << std::endl;
      std::cout << "Decoding column chunk " << i << ":" << j << ":"
                << std::endl;
      std::cout << "\tcompression: " << chunk.compression << std::endl;
      std::cout << "\ttype: " << chunk.type << std::endl;
      std::cout << "\toffset: " << chunk.offset
                << ", size: " << chunk.total_compressed_size << std::endl;

      auto start = std::chrono::high_resolution_clock::now();

      reader.enqueue_column_chunk(i, j);
      auto fpga_data_raw = reader.next_column_chunk();

      auto end = std::chrono::high_resolution_clock::now();
      auto fpga_us =
          std::chrono::duration_cast<std::chrono::microseconds>(end - start)
              .count();

      start = std::chrono::high_resolution_clock::now();

      auto cpu_data_raw = parcore::cpu::read_column_chunk(file, i, j);

      end = std::chrono::high_resolution_clock::now();
      auto cpu_us =
          std::chrono::duration_cast<std::chrono::microseconds>(end - start)
              .count();
      std::cout << "\tcompleted! FPGA took " << fpga_us << "us, CPU took "
                << cpu_us << "us" << std::endl;

      std::vector<uint8_t> fpga_data;
      for (auto buf : fpga_data_raw) {
        auto ptr = reinterpret_cast<uint8_t *>(buf->ptr);
        fpga_data.insert(fpga_data.end(), ptr, ptr + buf->size);
      }
      std::vector<uint8_t> cpu_data;
      for (const auto &cc : cpu_data_raw->chunks()) {
        auto arr = std::static_pointer_cast<arrow::PrimitiveArray>(cc);
        const uint8_t *data = arr->data()->GetValues<uint8_t>(1);
        size_t byte_size = arr->length() * libstf::size_of(typ);
        cpu_data.insert(cpu_data.end(), data, data + byte_size);
      }

      diff(cpu_data.data(), fpga_data.data(), fpga_data.size());
    }
  }

  Profiler::flush();
  return EXIT_SUCCESS;
}
