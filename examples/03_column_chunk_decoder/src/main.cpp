#include <getopt.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <arrow/io/file.h>
#include <parquet/column_reader.h>
#include <parquet/file_reader.h>
#include <parquet/metadata.h>

#include <coyote/cThread.hpp>
#include <libstf/buffer.hpp>
#include <libstf/common.hpp>
#include <libstf/configuration.hpp>
#include <libstf/error_handling.hpp>
#include <libstf/memory_pool.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/tlb_manager.hpp>
#include <parcore/column_chunk_decoder.hpp>
#include <parcore/configuration.hpp>
#include <parcore/metadata/metadata.hpp>

using namespace libstf;

struct Args {
    std::vector<std::string> files;
    std::vector<std::string> columns;
    size_t                   first_group = 0;
    size_t                   num_groups  = SIZE_MAX;
    size_t                   decoders = 0;
    size_t                   reps     = 10;
    size_t                   depth    = 4;
    bool                     verify   = false;
};

void print_usage(const char *prog) {
    std::cerr << "Usage: " << prog << " [OPTIONS] FILE...\n"
              << "\n"
              << "Decodes all supported columns of the given Parquet files with the ParCore\n"
              << "bitstream and prints one CSV row per column.\n"
              << "\n"
              << "Options:\n"
              << "  -D, --decoders N  Decoders to use, 0 for all of the design (default: 0)\n"
              << "  -r, --reps N      Repetitions per column (default: 10)\n"
              << "  -d, --depth N     Column chunks kept in flight per decoder (default: 4)\n"
              << "  -c, --columns C   Comma-separated names of the columns to decode (default: all)\n"
              << "  -g, --row-groups F[:N]  Decode only N row groups starting at F (default: all)\n"
              << "  -v, --verify      Compare every column chunk against Arrow's decoding first\n"
              << "  -h, --help        Show this help message\n";
}

Args parse_args(int argc, char *argv[]) {
    Args args;

    static struct option long_options[] = {{"decoders", required_argument, 0, 'D'},
                                           {"reps", required_argument, 0, 'r'},
                                           {"depth", required_argument, 0, 'd'},
                                           {"columns", required_argument, 0, 'c'},
                                           {"row-groups", required_argument, 0, 'g'},
                                           {"verify", no_argument, 0, 'v'},
                                           {"help", no_argument, 0, 'h'},
                                           {0, 0, 0, 0}};

    int opt;
    while ((opt = getopt_long(argc, argv, "D:r:d:c:g:vh", long_options, nullptr)) != -1) {
        switch (opt) {
        case 'D':
            args.decoders = std::stoul(optarg);
            break;
        case 'r':
            args.reps = std::stoul(optarg);
            break;
        case 'd':
            args.depth = std::stoul(optarg);
            break;
        case 'g': {
            std::string range = optarg;
            auto        colon = range.find(':');
            args.first_group  = std::stoul(range.substr(0, colon));
            if (colon != std::string::npos) {
                args.num_groups = std::stoul(range.substr(colon + 1));
            }
            break;
        }
        case 'c': {
            std::string columns = optarg;
            for (size_t start = 0, end; start <= columns.size(); start = end + 1) {
                end = std::min(columns.find(',', start), columns.size());
                args.columns.push_back(columns.substr(start, end - start));
            }
            break;
        }
        case 'v':
            args.verify = true;
            break;
        case 'h':
            print_usage(argv[0]);
            exit(0);
        default:
            print_usage(argv[0]);
            exit(1);
        }
    }

    for (int i = optind; i < argc; ++i) {
        args.files.push_back(argv[i]);
    }
    if (args.files.empty()) {
        print_usage(argv[0]);
        exit(1);
    }

    return args;
}

parcore::metadata::Type from_parquet_type(parquet::Type::type t) {
    switch (t) {
    case parquet::Type::BOOLEAN:
        return parcore::metadata::Type::BYTE_T;
    case parquet::Type::INT32:
        return parcore::metadata::Type::INT32_T;
    case parquet::Type::INT64:
        return parcore::metadata::Type::INT64_T;
    case parquet::Type::FLOAT:
        return parcore::metadata::Type::FLOAT_T;
    case parquet::Type::DOUBLE:
        return parcore::metadata::Type::DOUBLE_T;
    case parquet::Type::BYTE_ARRAY:
        return parcore::metadata::Type::BYTE_ARRAY;
    default:
        throw std::runtime_error("unsupported parquet physical type");
    }
}

parcore::metadata::Compression from_parquet_compression(arrow::Compression::type c) {
    switch (c) {
    case arrow::Compression::UNCOMPRESSED:
        return parcore::metadata::Compression::RAW;
    case arrow::Compression::SNAPPY:
        return parcore::metadata::Compression::SNAPPY;
    default:
        throw std::runtime_error("unsupported parquet compression");
    }
}

parcore::metadata::Metadata read_metadata(std::shared_ptr<arrow::io::RandomAccessFile> file,
                                          std::vector<bool> &has_rep_levels) {
    auto        file_metadata = parquet::ReadMetaData(file);
    const auto *schema        = file_metadata->schema();

    parcore::metadata::Metadata meta;
    for (int j = 0; j < schema->num_columns(); ++j) {
        meta.column_names.push_back(schema->Column(j)->name());
        has_rep_levels.push_back(schema->Column(j)->max_repetition_level() > 0);
    }

    for (int i = 0; i < file_metadata->num_row_groups(); ++i) {
        auto                       rg = file_metadata->RowGroup(i);
        parcore::metadata::RowGroup group;
        for (int j = 0; j < rg->num_columns(); ++j) {
            auto                          cc = rg->ColumnChunk(j);
            parcore::metadata::ColumnChunk chunk;
            chunk.type        = from_parquet_type(schema->Column(j)->physical_type());
            chunk.num_values  = cc->num_values();
            chunk.compression = from_parquet_compression(cc->compression());
            // A dictionary-encoded column chunk begins with its dictionary page, which lies before
            // the data_page_offset. total_compressed_size covers the whole chunk.
            chunk.offset = cc->has_dictionary_page() ? cc->dictionary_page_offset()
                                                     : cc->data_page_offset();
            chunk.total_compressed_size = cc->total_compressed_size();
            chunk.is_required           = schema->Column(j)->max_definition_level() == 0;
            group.chunks.push_back(chunk);
        }
        meta.groups.push_back(std::move(group));
    }

    return meta;
}

// ParCore does not strip repetition levels, so columns that have them are not supported.
bool is_supported(const parcore::metadata::ColumnChunk &chunk, bool has_rep_levels) {
    return !has_rep_levels && (parcore::metadata::is_libstf_type(chunk.type) ||
                               parcore::metadata::is_string_type(chunk.type));
}

std::shared_ptr<Buffer> load_chunk(std::shared_ptr<arrow::io::RandomAccessFile> file,
                                   const parcore::metadata::ColumnChunk &chunk,
                                   std::shared_ptr<MemoryPool>           pool) {
    Status status;
    auto   buffer = make_buffer(pool, chunk.total_compressed_size, status);
    check_status(status);

    auto read = file->ReadAt(chunk.offset, chunk.total_compressed_size, buffer->ptr);
    if (!read.ok() || *read != (int64_t)chunk.total_compressed_size) {
        throw std::runtime_error("could not read column chunk: " + read.status().ToString());
    }
    return buffer;
}

// The output of one column chunk. String chunks write their german_str_t records to the values
// stream and the strings that do not fit inline to the heap stream.
struct Output {
    std::vector<std::shared_ptr<Buffer>> values;
    std::vector<std::shared_ptr<Buffer>> heap;

    size_t size() const {
        size_t bytes = 0;
        for (const auto *buffers : {&values, &heap}) {
            for (const auto &buffer : *buffers) {
                bytes += buffer->size;
            }
        }
        return bytes;
    }
};

std::vector<uint8_t> concatenate(const std::vector<std::shared_ptr<Buffer>> &buffers) {
    std::vector<uint8_t> bytes;
    for (const auto &buffer : buffers) {
        auto data = static_cast<const uint8_t *>(buffer->ptr);
        bytes.insert(bytes.end(), data, data + buffer->size);
    }
    return bytes;
}

// Passes the outputs to `on_output` in row group order.
void decode_column(const std::vector<std::shared_ptr<parcore::ColumnChunkDecoder>> &decoders,
                   const parcore::metadata::Metadata                               &meta,
                   const std::vector<std::vector<std::shared_ptr<Buffer>>>         &data, size_t j,
                   size_t depth, const std::function<void(size_t, const Output &)> &on_output) {
    struct Pending {
        std::shared_ptr<parcore::ColumnChunkDecoder> decoder;
        parcore::metadata::ColumnChunk               chunk;
        std::shared_ptr<OutputHandle>                output;
    };

    size_t              num_chunks = meta.groups.size();
    std::deque<Pending> pending;
    std::vector<size_t> in_flight(decoders.size(), 0);
    size_t              next = 0;

    for (size_t done = 0; done < num_chunks; ++done) {
        for (; next < num_chunks && in_flight[next % decoders.size()] < depth; ++next) {
            auto &decoder = decoders[next % decoders.size()];
            auto &chunk   = meta.groups[next].chunks[j];

            auto handle = decoder->decode_column_chunk(chunk);
            handle->add_chunk(data[next][j]);
            pending.push_back({decoder, chunk, std::move(*handle).done()});
            in_flight[next % decoders.size()] += 1;
        }

        auto   p = std::move(pending.front());
        Output output;
        pending.pop_front();
        while (p.output->stream_has_more_output(p.decoder->values_stream())) {
            output.values.push_back(p.output->get_next_stream_output(p.decoder->values_stream()));
        }
        if (parcore::metadata::is_string_type(p.chunk.type)) {
            while (p.output->stream_has_more_output(p.decoder->heap_stream())) {
                output.heap.push_back(p.output->get_next_stream_output(p.decoder->heap_stream()));
            }
        }
        p.decoder->finished_decoding_column_chunk(p.chunk);
        in_flight[done % decoders.size()] -= 1;

        on_output(done, output);
    }
}

// Reads the physical values of a column chunk. Like ParCore, the reader only returns the values of
// non-null entries.
template <typename DType>
std::vector<uint8_t> read_values(parquet::ColumnReader &reader, size_t num_values) {
    using T = typename DType::c_type;
    auto &typed = static_cast<parquet::TypedColumnReader<DType> &>(reader);

    constexpr int64_t    BATCH_SIZE = 1 << 16;
    std::vector<int16_t> def_levels(BATCH_SIZE);
    std::vector<T>       values(num_values);
    size_t               total = 0;
    while (typed.HasNext()) {
        int64_t values_read = 0;
        typed.ReadBatch(BATCH_SIZE, def_levels.data(), nullptr, values.data() + total,
                        &values_read);
        total += values_read;
    }

    auto bytes = reinterpret_cast<const uint8_t *>(values.data());
    return std::vector<uint8_t>(bytes, bytes + total * sizeof(T));
}

std::vector<std::string> read_strings(parquet::ColumnReader &reader) {
    auto &typed = static_cast<parquet::ByteArrayReader &>(reader);

    constexpr int64_t               BATCH_SIZE = 1 << 16;
    std::vector<int16_t>            def_levels(BATCH_SIZE);
    std::vector<parquet::ByteArray> values(BATCH_SIZE);
    std::vector<std::string>        strings;
    while (typed.HasNext()) {
        int64_t values_read = 0;
        typed.ReadBatch(BATCH_SIZE, def_levels.data(), nullptr, values.data(), &values_read);
        // The values point into the reader's page buffer, which the next batch overwrites
        for (int64_t k = 0; k < values_read; ++k) {
            strings.emplace_back(reinterpret_cast<const char *>(values[k].ptr), values[k].len);
        }
    }
    return strings;
}

// Checks the german_str_t records of a string chunk against the strings Arrow decodes. A record is
// laid out like DuckDB's string_t: the 4 byte length, then strings of up to 12 bytes inline and zero
// padded, longer ones as their first 4 bytes and a pointer. The heap only holds the strings longer
// than 12 bytes, back to back, of PLAIN pages per value and of a dictionary page once per entry. As
// the OutputBufferManager decides where the heap lands, the chunk is configured with heap address 0,
// which makes the pointers offsets into the heap.
void verify_strings(size_t i, size_t j, const std::vector<std::string> &expected,
                    const Output &output) {
    constexpr size_t RECORD_BYTES = 16, INLINE_BYTES = 12, PREFIX_BYTES = 4;
    auto             fail = [&](const std::string &msg) {
        throw std::runtime_error("column chunk " + std::to_string(i) + ":" + std::to_string(j) +
                                 ": " + msg);
    };

    auto records = concatenate(output.values);
    auto heap    = concatenate(output.heap);
    if (records.size() != expected.size() * RECORD_BYTES) {
        fail("expected " + std::to_string(expected.size()) + " string records, got " +
             std::to_string(records.size()) + " bytes");
    }

    for (size_t k = 0; k < expected.size(); ++k) {
        const auto    &str    = expected[k];
        const uint8_t *record = records.data() + k * RECORD_BYTES;

        uint32_t length;
        std::memcpy(&length, record, sizeof(length));

        uint8_t expected_record[RECORD_BYTES] = {};
        std::memcpy(expected_record, &length, sizeof(length));
        if (str.size() <= INLINE_BYTES) {
            std::memcpy(expected_record + 4, str.data(), str.size());
        } else {
            uint64_t heap_offset;
            std::memcpy(&heap_offset, record + 8, sizeof(heap_offset));
            std::memcpy(expected_record + 4, str.data(), PREFIX_BYTES);
            std::memcpy(expected_record + 8, &heap_offset, sizeof(heap_offset));
            if (heap_offset > heap.size() || str.size() > heap.size() - heap_offset ||
                std::memcmp(heap.data() + heap_offset, str.data(), str.size()) != 0) {
                fail("string " + std::to_string(k) + " is not in the heap at offset " +
                     std::to_string(heap_offset));
            }
        }
        if (length != str.size() || std::memcmp(record, expected_record, RECORD_BYTES) != 0) {
            fail("record of string " + std::to_string(k) + " does not match");
        }
    }
}

// Returns false if the chunk can't be compared byte by byte.
bool verify_chunk(parquet::ParquetFileReader &reader, size_t i, size_t j,
                  const parcore::metadata::ColumnChunk &chunk, const Output &output) {
    auto column = reader.RowGroup(i)->Column(j);

    if (parcore::metadata::is_string_type(chunk.type)) {
        verify_strings(i, j, read_strings(*column), output);
        return true;
    }

    std::vector<uint8_t> expected_bytes;
    switch (chunk.type) {
    case parcore::metadata::Type::INT32_T:
        expected_bytes = read_values<parquet::Int32Type>(*column, chunk.num_values);
        break;
    case parcore::metadata::Type::INT64_T:
        expected_bytes = read_values<parquet::Int64Type>(*column, chunk.num_values);
        break;
    case parcore::metadata::Type::FLOAT_T:
        expected_bytes = read_values<parquet::FloatType>(*column, chunk.num_values);
        break;
    case parcore::metadata::Type::DOUBLE_T:
        expected_bytes = read_values<parquet::DoubleType>(*column, chunk.num_values);
        break;
    default:
        // Parquet bit-packs booleans, but ParCore outputs them as bytes.
        return false;
    }

    auto actual_bytes = concatenate(output.values);

    if (actual_bytes.size() != expected_bytes.size()) {
        throw std::runtime_error("column chunk " + std::to_string(i) + ":" + std::to_string(j) +
                                 ": expected " + std::to_string(expected_bytes.size()) +
                                 " output bytes, got " + std::to_string(actual_bytes.size()));
    }
    auto mismatch =
        std::mismatch(expected_bytes.begin(), expected_bytes.end(), actual_bytes.begin());
    if (mismatch.first != expected_bytes.end()) {
        throw std::runtime_error("column chunk " + std::to_string(i) + ":" + std::to_string(j) +
                                 ": output mismatch at byte " +
                                 std::to_string(mismatch.first - expected_bytes.begin()));
    }
    return true;
}

double gibps(size_t bytes, double us) { return (bytes / 1073741824.0) / (us / 1000000.0); }

// The input and output stream profiling counters of the decoders, summed over all used decoders.
// Within a column chunk, every cycle of a stream is a handshake, starved (no valid data) or
// stalled (valid data, but not ready). Stalled input cycles mean the decoder is the bottleneck,
// starved ones that the input does not arrive fast enough. Reading the counters resets them, they
// start counting again with the next data beat.
struct Profile {
    static constexpr const char *HEADER =
        "in_beats,in_starved,in_stalled,out_beats,out_starved,out_stalled";

    parcore::StreamProfile in = {}, out = {};

    friend std::ostream &operator<<(std::ostream &os, const Profile &p) {
        return os << p.in.handshakes_cycles << "," << p.in.starved_cycles << ","
                  << p.in.stalled_cycles << "," << p.out.handshakes_cycles << ","
                  << p.out.starved_cycles << "," << p.out.stalled_cycles;
    }
};

Profile read_profiles(parcore::ColumnChunkDecoderConfig &config, size_t num_decoders) {
    Profile sum;
    for (size_t d = 0; d < num_decoders; ++d) {
        auto p = config.read_profile(d);
        for (auto [total, part] : {std::pair{&sum.in, &p.in}, std::pair{&sum.out, &p.out}}) {
            total->handshakes_cycles += part->handshakes_cycles;
            total->starved_cycles += part->starved_cycles;
            total->stalled_cycles += part->stalled_cycles;
            total->idle_cycles += part->idle_cycles;
            total->last_handshakes += part->last_handshakes;
        }
    }
    return sum;
}

int main(int argc, char *argv[]) {
    Args args = parse_args(argc, argv);

#ifdef EN_SIMULATION
    std::shared_ptr<MemoryPool> pool = std::make_shared<SimpleMemoryPool>();
#else
    std::shared_ptr<MemoryPool> pool = std::make_shared<HugePageMemoryPool>();
#endif

    OutputBufferManager *obm_ptr = nullptr;
    auto cthread = std::make_shared<coyote::cThread>(0, getpid(), 0, [&obm_ptr](int value) {
        if (obm_ptr)
            obm_ptr->handle_fpga_interrupt(value);
    });
    auto tlb = std::make_shared<TLBManager>(cthread, pool);

    GlobalConfig global_config(cthread);
    auto         mem_config    = global_config.get_config<MemConfig>();
    auto         decoder_config = global_config.get_config<parcore::ColumnChunkDecoderConfig>();

    // ColumnChunkDecoder keeps one config FIFO slot free.
    size_t max_depth = decoder_config->maximum_num_enqueued_configs() - 1;
    if (args.depth < 1 || args.depth > max_depth) {
        throw std::runtime_error("depth must be in [1, " + std::to_string(max_depth) + "]");
    }

#ifdef EN_SIMULATION
    auto obm = std::make_shared<OutputBufferManager>(cthread, mem_config, pool, tlb,
                                                     ~stream_mask_t(0), 2, 1 << 21);
#else
    auto obm = std::make_shared<OutputBufferManager>(cthread, mem_config, pool, tlb,
                                                     ~stream_mask_t(0), 40, 1 << 23);
#endif
    obm_ptr = obm.get();

    // Pre-map all huge pages, so that no TLB mappings are created while measuring
    if (auto huge_pool = std::dynamic_pointer_cast<HugePageMemoryPool>(pool)) {
        tlb->ensure_tlb_mapping(huge_pool->initial_address(), huge_pool->total_capacity());
    }
    obm->flush_buffers();

    size_t num_decoders = decoder_config->num_decoders();
    if (args.decoders > 0) {
        num_decoders = std::min(args.decoders, num_decoders);
    }
    std::vector<std::shared_ptr<parcore::ColumnChunkDecoder>> decoders;
    for (size_t d = 0; d < num_decoders; ++d) {
        decoders.push_back(
            std::make_shared<parcore::ColumnChunkDecoder>(cthread, tlb, obm, decoder_config, d));
    }

    std::cout << "file,column,name,type,row_groups,num_values,in_bytes,out_bytes,us,in_gibps,"
                 "out_gibps,verified,"
              << Profile::HEADER << std::endl;

    for (const auto &path : args.files) {
        auto maybe_file = arrow::io::ReadableFile::Open(path);
        if (!maybe_file.ok()) {
            throw std::runtime_error("could not open " + path + ": " +
                                     maybe_file.status().ToString());
        }
        auto file = *maybe_file;
        std::vector<bool> has_rep_levels;
        auto              meta = read_metadata(file, has_rep_levels);
        size_t first_group = std::min(args.first_group, meta.groups.size());
        size_t last_group  = first_group + std::min(args.num_groups, meta.groups.size() - first_group);
        meta.groups = {meta.groups.begin() + first_group, meta.groups.begin() + last_group};
        if (meta.groups.empty()) {
            continue;
        }

        std::unique_ptr<parquet::ParquetFileReader> reader;
        if (args.verify) {
            reader = parquet::ParquetFileReader::Open(file);
        }

        // Only the chunks of the column being decoded are kept in memory, so that files larger
        // than the huge page pool work.
        std::vector<std::vector<std::shared_ptr<Buffer>>> data(
            meta.groups.size(), std::vector<std::shared_ptr<Buffer>>(meta.column_names.size()));

        for (size_t j = 0; j < meta.column_names.size(); ++j) {
            if (!is_supported(meta.groups[0].chunks[j], has_rep_levels[j])) {
                continue;
            }
            if (!args.columns.empty() && std::find(args.columns.begin(), args.columns.end(),
                                                   meta.column_names[j]) == args.columns.end()) {
                continue;
            }

            for (size_t i = 0; i < meta.groups.size(); ++i) {
                data[i][j] = load_chunk(file, meta.groups[i].chunks[j], pool);
            }

            size_t verified = 0;
            if (args.verify) {
                decode_column(decoders, meta, data, j, 1, [&](size_t i, const Output &output) {
                    verified += verify_chunk(*reader, first_group + i, j, meta.groups[i].chunks[j],
                                             output);
                });
            }

            size_t in_bytes = 0, out_bytes = 0, num_values = 0;
            for (const auto &group : meta.groups) {
                in_bytes += group.chunks[j].total_compressed_size;
                num_values += group.chunks[j].num_values;
            }

            read_profiles(*decoder_config, num_decoders);
            auto start = std::chrono::high_resolution_clock::now();
            for (size_t rep = 0; rep < args.reps; ++rep) {
                out_bytes = 0;
                decode_column(decoders, meta, data, j, args.depth,
                              [&](size_t, const Output &output) { out_bytes += output.size(); });
            }
            auto end = std::chrono::high_resolution_clock::now();
            auto us  = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count() /
                      (double)std::max<size_t>(args.reps, 1);
            auto profile = read_profiles(*decoder_config, num_decoders);

            std::cout << path << "," << j << "," << meta.column_names[j] << ","
                      << meta.groups[0].chunks[j].type << "," << meta.groups.size() << ","
                      << num_values << "," << in_bytes << "," << out_bytes << "," << us << ","
                      << gibps(in_bytes, us) << "," << gibps(out_bytes, us) << ","
                      << (args.verify ? std::to_string(verified) + "/" +
                                            std::to_string(meta.groups.size())
                                      : "-")
                      << "," << profile << std::endl;

            for (auto &group : data) {
                group[j] = nullptr;
            }
        }
    }

    return EXIT_SUCCESS;
}
