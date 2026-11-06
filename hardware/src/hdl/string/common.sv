package parcore_string;

import libstf::*;

// Widths of the string decoding datapath
parameter int STRING_BEAT_WIDTH   = 64;
parameter int STRING_EXTEND_WIDTH = 15; // Bytes of the next beat seen by the LengthExtractor
parameter int STRING_N            = 4;  // Strings per cycle

parameter int STRING_PREFIX_BYTES = 4;  // Length prefix of a PLAIN encoded string
parameter int STRING_INLINE_BYTES = 12; // String bytes stored in a german string

// Output beat of the LengthExtractor
typedef struct packed {
    data8_t[STRING_BEAT_WIDTH - 1:0]                          data;
    data32_t[STRING_N - 1:0]                                  lengths;
    data8_t[STRING_N - 1:0][STRING_INLINE_BYTES - 1:0]        inline_bytes; // Bytes after each prefix
    logic  [STRING_N - 1:0][$clog2(STRING_BEAT_WIDTH) - 1:0]  positions;
    logic  [STRING_N - 1:0]                                   length_keep;
    logic                                                     duplicate;
} length_beat_t;

endpackage
