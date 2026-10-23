#pragma once

#include <cstdint>
#include <istream>
#include <string>
#include <vector>

#include <libstf/common.hpp>

namespace parcore {
namespace metadata {

std::string read_string(std::istream &is);

enum class Compression : uint8_t { RAW = 0, SNAPPY = 1 };
std::ostream &operator<<(std::ostream &os, Compression c);

enum class Type : unsigned char {
  BYTE_T = 0,
  INT32_T = 1,
  INT64_T = 2,
  FLOAT_T = 3,
  DOUBLE_T = 4,
  BYTE_ARRAY = 5
};
std::ostream &operator<<(std::ostream &os, Type typ);
/**
 * Whether the type decodes into a flat run of fixed-width values. BYTE_ARRAY is
 * excluded: the hardware decodes it, but into german_str_t records plus a
 * separate string heap. Use is_string_type for that.
 */
bool is_libstf_type(const Type &typ);
bool is_string_type(const Type &typ);
// libstf has no string type, so german strings travel as its 128 bit type. Matches GERMAN_STR_T in
// hardware/src/hdl/common.sv.
constexpr libstf::type_t GERMAN_STR_T = libstf::type_t::INT128_T;

libstf::type_t to_libstf_type(const Type &typ);

struct ColumnChunk {
  Type type;
  uint64_t num_values;
  Compression compression;
  uint64_t offset;
  uint64_t total_compressed_size;
  // True for REQUIRED columns, i.e. max_definition_level == 0, whose data pages carry no definition
  // levels. A REQUIRED leaf below an OPTIONAL group has definition levels and is thus not required.
  // Columns with repetition levels (max_repetition_level > 0) are not supported at all.
  // Not part of the binary format read by from(), which keeps the default.
  bool is_required = false;
  // Bit width of the column's integer logical type annotation (INT(bit_width, is_signed) or the
  // converted types INT_8 ... UINT_64), 0 if the column has none.
  uint8_t logical_width = 0;

  libstf::type_t logical_type() const;

  static ColumnChunk from(std::istream &is);
  bool operator==(const ColumnChunk &rhs) const;
};

struct RowGroup {
  std::vector<ColumnChunk> chunks;

  static RowGroup from(std::istream &is);
  bool operator==(const RowGroup &rhs) const;
};

struct Metadata {
  std::vector<std::string> column_names;
  std::vector<RowGroup> groups;

  static Metadata from(std::istream &is);
  bool operator==(const Metadata &rhs) const;
};

} // namespace metadata
}; // namespace parcore
