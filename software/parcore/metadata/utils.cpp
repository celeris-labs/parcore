#include <parcore/metadata/utils.hpp>

#include <parquet/file_reader.h>
#include <parquet/metadata.h>
#include <parquet/schema.h>
#include <parquet/types.h>

#include <arrow/io/file.h>
#include <arrow/util/type_fwd.h>

#include <stdexcept>

namespace parcore {
namespace metadata {

static Type from_parquet_type(parquet::Type::type t) {
  switch (t) {
  case parquet::Type::BOOLEAN:
    return Type::BYTE_T;
  case parquet::Type::INT32:
    return Type::INT32_T;
  case parquet::Type::INT64:
    return Type::INT64_T;
  case parquet::Type::FLOAT:
    return Type::FLOAT_T;
  case parquet::Type::DOUBLE:
    return Type::DOUBLE_T;
  case parquet::Type::BYTE_ARRAY:
    return Type::BYTE_ARRAY;
  default:
    throw std::runtime_error("unsupported parquet physical type");
  }
}

static Compression from_parquet_compression(arrow::Compression::type c) {
  switch (c) {
  case arrow::Compression::UNCOMPRESSED:
    return Compression::RAW;
  case arrow::Compression::SNAPPY:
    return Compression::SNAPPY;
  default:
    throw std::runtime_error("unsupported parquet compression");
  }
}

Metadata from_file(const std::string &path) {
  auto maybe_file = arrow::io::ReadableFile::Open(path);
  if (!maybe_file.ok())
    throw std::runtime_error("could not open parquet file: " +
                             maybe_file.status().message());

  auto file_metadata = parquet::ReadMetaData(maybe_file.ValueOrDie());
  const auto *schema = file_metadata->schema();

  Metadata meta;

  int num_cols = schema->num_columns();
  meta.column_names.reserve(num_cols);
  for (int i = 0; i < num_cols; ++i)
    meta.column_names.push_back(schema->Column(i)->name());

  int num_rgs = file_metadata->num_row_groups();
  meta.groups.reserve(num_rgs);
  for (int i = 0; i < num_rgs; ++i) {
    auto rg = file_metadata->RowGroup(i);
    RowGroup group;
    group.chunks.reserve(num_cols);
    for (int j = 0; j < rg->num_columns(); ++j) {
      auto cc = rg->ColumnChunk(j);
      ColumnChunk chunk;
      chunk.type = from_parquet_type(schema->Column(j)->physical_type());
      chunk.num_values = static_cast<uint64_t>(cc->num_values());
      chunk.compression = from_parquet_compression(cc->compression());
      // A column chunk that is dictionary-encoded begins with a dictionary page, so the chunk's
      // first byte is dictionary_page_offset, not data_page_offset (which points *past* the
      // dictionary page). total_compressed_size covers the whole chunk including that dictionary
      // page, so reading total_compressed_size bytes from data_page_offset would start too late and
      // overrun the chunk. Prefer the dictionary page offset when present -- matching how the DuckDB
      // extension computes it (parcore_metadata_util.cpp).
      chunk.offset = static_cast<uint64_t>(cc->has_dictionary_page()
                                               ? cc->dictionary_page_offset()
                                               : cc->data_page_offset());
      chunk.total_compressed_size =
          static_cast<uint64_t>(cc->total_compressed_size());
      // A level section (and thus its length prefix) only precedes the page body
      // when the schema says it's needed.      
      chunk.has_rep_levels = schema->Column(j)->max_repetition_level() > 0;
      chunk.has_def_levels = schema->Column(j)->max_definition_level() > 0;
      group.chunks.push_back(chunk);
    }
    meta.groups.push_back(std::move(group));
  }

  return meta;
}

} // namespace metadata
} // namespace parcore
