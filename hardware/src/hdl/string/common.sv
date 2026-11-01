package parcore_string;

import libstf::*;

// Widths of the string decoding datapath, overridden by the defines in tests
`ifndef PARCORE_STRING_BEAT_WIDTH
`define PARCORE_STRING_BEAT_WIDTH 64
`endif
`ifndef PARCORE_STRING_EXTEND_WIDTH
`define PARCORE_STRING_EXTEND_WIDTH 15
`endif
`ifndef PARCORE_STRING_N
`define PARCORE_STRING_N 4
`endif

parameter int STRING_BEAT_WIDTH   = `PARCORE_STRING_BEAT_WIDTH;
parameter int STRING_EXTEND_WIDTH = `PARCORE_STRING_EXTEND_WIDTH;
parameter int STRING_N            = `PARCORE_STRING_N; // Strings per cycle

// Output beat of the LengthExtractor
typedef struct packed {
    data8_t [STRING_BEAT_WIDTH + STRING_EXTEND_WIDTH - 1:0]   data;
    logic   [STRING_BEAT_WIDTH + STRING_EXTEND_WIDTH - 1:0]   data_keep;
    data32_t[STRING_N - 1:0]                                  lengths;
    logic   [STRING_N - 1:0][$clog2(STRING_BEAT_WIDTH) - 1:0] positions;
    logic   [STRING_N - 1:0]                                  length_keep;
    logic                                                     duplicate;
} length_beat_t;

endpackage
