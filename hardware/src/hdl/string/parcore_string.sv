// Types and widths that only the string decoding modules use
package parcore_string;

import libstf::*;

// Widths of the string decoding datapath
parameter int STRING_BEAT_WIDTH   = 64;
parameter int STRING_EXTEND_WIDTH = 15; // Bytes of the next beat seen by the LengthExtractor
parameter int STRINGS_PER_CYCLE   = 4;  // The LengthExtractor follows 4 length prefixes per cycle

parameter int STRING_PREFIX_BYTES = 4;  // Length prefix of a PLAIN encoded string
parameter int STRING_INLINE_BYTES = 12; // String bytes stored in a german string

// Output beat of the LengthExtractor
typedef struct packed {
    data8_t[STRING_BEAT_WIDTH - 1:0]                                   data;
    data32_t[STRINGS_PER_CYCLE - 1:0]                                  lengths;
    data8_t[STRINGS_PER_CYCLE - 1:0][STRING_INLINE_BYTES - 1:0]        inline_bytes; // Bytes after each prefix
    logic  [STRINGS_PER_CYCLE - 1:0][$clog2(STRING_BEAT_WIDTH) - 1:0]  positions;
    logic  [STRINGS_PER_CYCLE - 1:0]                                   length_keep;
    logic                                                              duplicate;
} length_beat_t;

// Per page configuration of the ParallelStringDecoder. The first page of a column chunk sets the
// address its heap starts at, the following pages continue after the heap of the page before.
typedef struct packed {
    logic      update_buffer_addr;
    vaddress_t buffer_addr;
} string_decoder_conf_t;

// Per page configuration of the PlainPageRouter
typedef struct packed {
    logic is_string;
    logic is_dictionary;
} plain_page_conf_t;

endpackage
