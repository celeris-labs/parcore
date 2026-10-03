#include <parcore/metadata/metadata.hpp>

#include <iostream>
#include <ostream>
#include <stdexcept>

namespace parcore {
namespace metadata {

std::ostream &operator<<(std::ostream &os, Type typ) {
  switch (typ) {
  case Type::BYTE_T:
    return os << "BYTE_T";
  case Type::INT32_T:
    return os << "INT32_T";
  case Type::INT64_T:
    return os << "INT64_T";
  case Type::FLOAT_T:
    return os << "FLOAT_T";
  case Type::DOUBLE_T:
    return os << "DOUBLE_T";
  default:
    return os << "UNEXPECTED TYPE";
  }
}

bool is_libstf_type(const Type &typ) {
  switch (typ) {
  case Type::BYTE_T:
  case Type::INT32_T:
  case Type::INT64_T:
  case Type::FLOAT_T:
  case Type::DOUBLE_T:
    return true;
  default:
    return false;
  }
}

libstf::type_t to_libstf_type(const Type &typ) {
  switch (typ) {
  case Type::BYTE_T:
    return libstf::type_t::BYTE_T;
  case Type::INT32_T:
    return libstf::type_t::INT32_T;
  case Type::INT64_T:
    return libstf::type_t::INT64_T;
  case Type::FLOAT_T:
    return libstf::type_t::FLOAT_T;
  case Type::DOUBLE_T:
    return libstf::type_t::DOUBLE_T;
  default:
    throw std::runtime_error("cannot convert type to libstf::type_t");
  }
}

std::ostream &operator<<(std::ostream &os, Compression c) {
  switch (c) {
  case Compression::RAW:
    return os << "RAW";
  case Compression::SNAPPY:
    return os << "SNAPPY";
  default:
    return os << "UNEXPECTED COMPRESSION";
  }
}

static void read_exact(std::istream &is, void *dst, size_t n) {
  if (!is.read(reinterpret_cast<char *>(dst), n))
    throw std::runtime_error("unexpected EOF");
}

template <typename Enum> static void read_enum(std::istream &is, Enum *dst) {
  static_assert(sizeof(Enum) == 1, "Enum must be 1 byte");
  uint8_t val = 123;
  if (!is.read(reinterpret_cast<char *>(&val), 1))
    throw std::runtime_error("unexpected EOF reading enum");

  *dst = static_cast<Enum>(val);
}

static void read_bool(std::istream &is, bool *dst) {
  uint8_t val;
  if (!is.read(reinterpret_cast<char *>(&val), 1))
    throw std::runtime_error("unexpected EOF reading bool");

  *dst = val != 0;
}

std::string read_string(std::istream &is) {
  uint32_t n;
  read_exact(is, &n, sizeof(uint32_t));

  std::string str(n, '\0');
  read_exact(is, str.data(), n);
  return str;
}

ColumnChunk ColumnChunk::from(std::istream &is) {
  ColumnChunk c;

  read_enum(is, &c.type);
  read_exact(is, &c.num_values, sizeof(c.num_values));
  read_enum(is, &c.compression);
  read_exact(is, &c.offset, sizeof(c.offset));
  read_exact(is, &c.total_compressed_size, sizeof(c.total_compressed_size));
  read_bool(is, &c.has_rep_levels);
  read_bool(is, &c.has_def_levels);

  return c;
}

bool ColumnChunk::operator==(const ColumnChunk &rhs) const {
  return type == rhs.type && num_values == rhs.num_values &&
         compression == rhs.compression && offset == rhs.offset &&
         total_compressed_size == rhs.total_compressed_size &&
         has_rep_levels == rhs.has_rep_levels && has_def_levels == rhs.has_def_levels;
}

RowGroup RowGroup::from(std::istream &is) {
  RowGroup g;
  uint32_t n;
  read_exact(is, &n, sizeof(uint32_t));
  g.chunks.reserve(n);
  for (uint32_t i = 0; i < n; ++i)
    g.chunks.push_back(ColumnChunk::from(is));
  return g;
}

bool RowGroup::operator==(const RowGroup &rhs) const {
  return chunks == rhs.chunks;
}

Metadata Metadata::from(std::istream &is) {
  Metadata m;
  uint32_t n;

  read_exact(is, &n, sizeof(uint32_t));
  m.column_names.reserve(n);
  for (uint32_t i = 0; i < n; ++i)
    m.column_names.push_back(read_string(is));

  read_exact(is, &n, sizeof(uint32_t));
  m.groups.reserve(n);
  for (uint32_t i = 0; i < n; ++i)
    m.groups.push_back(RowGroup::from(is));
  return m;
}

bool Metadata::operator==(const Metadata &rhs) const {
  return column_names == rhs.column_names && groups == rhs.groups;
}

const ColumnChunk get_column_chunk(const Metadata &meta, size_t chunk,
                                   size_t column) {
  if (chunk >= meta.groups.size()) {
    throw std::runtime_error("attempted to parse chunk which is out of bounds");
  }
  auto group = meta.groups[chunk];

  if (column >= group.chunks.size()) {
    throw std::runtime_error(
        "attempted to parse column chunk which is out of bounds");
  }

  return group.chunks[column];
}

} // namespace metadata
} // namespace parcore
