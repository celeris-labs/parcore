#include <boost/program_options.hpp>
#include <boost/program_options/value_semantic.hpp>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <stdexcept>
#include <string>

#include <arrow/array.h>
#include <coyote/cDefs.hpp>
#include <coyote/cThread.hpp>
#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/tlb_manager.hpp>
#include <parcore/adaptor.hpp>
#include <parcore/column_chunk_decoder.hpp>
#include <parcore/metadata/utils.hpp>
#include <parcore/multi_reader.hpp>
#include <unistd.h>

// Default vFPGA to assign cThreads to; for designs with one region (vFPGA) this
// is the only possible value
#define DEFAULT_VFPGA_ID 0
#define N_REPS 10
#define N_ENQUEUE 5

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

void benchmark(std::string path, uint32_t num_decoders, size_t reps) {
  auto meta = parcore::metadata::from_file(path);
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

  auto maybe_file =
      arrow::io::MemoryMappedFile::Open(path, arrow::io::FileMode::READ);
  if (!maybe_file.ok())
    throw std::runtime_error("could not open parquet file: " +
                             maybe_file.status().message());
  auto file = maybe_file.ValueOrDie();

  libstf::GlobalConfig global_config(cthread);
  auto mem_config = global_config.get_config<libstf::MemConfig>();
  auto column_chunk_config =
      global_config.get_config<parcore::ColumnChunkDecoderConfig>();

#ifdef ENABLE_SIMULATION
  obm = std::make_shared<libstf::OutputBufferManager>(
      cthread, mem_config, pool, tlb, 2, 1 << 21 /* 2MiB */);
#else
  obm = std::make_shared<libstf::OutputBufferManager>(
      cthread, mem_config, pool, tlb, 40, 1 << 23 /* 8MiB */);
#endif
  obm->flush_buffers();

  if (num_decoders <= 0)
    num_decoders = column_chunk_config->num_decoders();

  std::vector<std::shared_ptr<parcore::ColumnChunkDecoder>> decoders;
  for (size_t i = 0; i < num_decoders; ++i)
    decoders.push_back(std::make_shared<parcore::ColumnChunkDecoder>(
        cthread, tlb, obm, column_chunk_config, i));

  std::vector<std::shared_ptr<parcore::Reader>> readers;
  for (size_t i = 0; i < num_decoders; ++i)
    readers.push_back(std::make_shared<parcore::adapted::PreloadFileReader>(
        decoders[i], pool, meta, file));

  auto hardware_reader = std::make_shared<parcore::MultiReader>(readers);

  auto rows = meta.groups.size();
  assert(rows > 0);
  auto cols = meta.groups[0].chunks.size();

  for (size_t j = 0; j < cols; ++j) {
    auto first_column_chunk = meta.groups[0].chunks[j];
    auto typ = first_column_chunk.type;
    if (!parcore::metadata::is_libstf_type(typ))
      continue;

    size_t byte_size = libstf::size_of(parcore::metadata::to_libstf_type(typ));
    size_t in_bytes = 0;
    size_t out_bytes = 0;
    size_t num_values = 0;
    for (size_t i = 0; i < rows; ++i) {
      auto cc = meta.groups[i].chunks[j];
      assert(cc.type == typ);

      in_bytes += cc.total_compressed_size;

      out_bytes += cc.num_values * byte_size;
      num_values += cc.num_values;
    }
    auto total_bytes = out_bytes + in_bytes;

    double us = 0.0;
    for (size_t k = 0; k < reps; ++k) {
      auto start = std::chrono::high_resolution_clock::now();

      auto preload = std::min((size_t)N_ENQUEUE, rows);
      for (size_t i = 0; i < preload; ++i) {
        hardware_reader->enqueue_column_chunk(i, j);
      }

      for (size_t i = 0; i < rows; ++i) {
        if (i + preload < rows)
          hardware_reader->enqueue_column_chunk(preload + i, j);

        auto fpga_data = hardware_reader->next_column_chunk();
        if (fpga_data->num_chunks() > 1)
          throw std::runtime_error(
              "expected just 1 output buffer for maximum performance");
      }

      auto end = std::chrono::high_resolution_clock::now();
      us += std::chrono::duration_cast<std::chrono::microseconds>(end - start)
                .count();
    }

    us /= reps;
    double gbps =
        (std::max(in_bytes, out_bytes) / 1073741824.0) / (us / 1000000.0);

    double in_out_bytes_ratio = ((double)in_bytes) / ((double)out_bytes);

    std::cout << path << "," << j << "," << num_values << "," << typ << ","
              << in_bytes << "," << out_bytes << "," << in_out_bytes_ratio
              << "," << total_bytes << "," << us << "," << gbps << std::endl;
  }
}

int main(int argc, char *argv[]) {
  std::vector<std::string> files;
  size_t reps;
  uint32_t num_decoders;

  boost::program_options::options_description runtime_options(
      "Parcore benchmark");
  runtime_options.add_options()(
      "file,f", boost::program_options::value(&files)->multitoken(),
      "Path to the parquet files to benchmark on")(
      "reps,r",
      boost::program_options::value<size_t>(&reps)->default_value(N_REPS),
      "The number of times to decode each page for benchmarking")(
      "num_decoders,D",
      boost::program_options::value<uint32_t>(&num_decoders)->default_value(0),
      "The number of decoders to use; 0 means as many as possible");
  boost::program_options::variables_map command_line_arguments;
  boost::program_options::store(
      boost::program_options::parse_command_line(argc, argv, runtime_options),
      command_line_arguments);
  boost::program_options::notify(command_line_arguments);

  std::cout << "file,column,num_values,type,in_bytes,out_bytes,in_out_bytes_"
               "ratio,total_bytes,time,GiBps"
            << std::endl;
  for (auto file : files) {
    benchmark(file, num_decoders, reps);
  }

  return EXIT_SUCCESS;
}
