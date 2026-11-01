`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;
import parcore_string::*;

// Decodes PLAIN encoded string pages into german strings and the heap with up to N strings per
// cycle. See docs/strings/parallel_string_decoder.md.
module ParallelStringDecoder #(
    parameter int DATABEAT_SIZE = STRING_BEAT_WIDTH,
    parameter int EXTEND_WIDTH  = STRING_EXTEND_WIDTH,
    parameter int N             = STRING_N
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,        // #(plain_str_decoder_conf_t)
    ndata_i.s       in_data,     // #(data8_t, DATABEAT_SIZE)

    ndata_i.m       out_strings, // #(data8_t, DATABEAT_SIZE) german strings
    ndata_i.m       out_heap     // #(data8_t, DATABEAT_SIZE) heap bytes selected by keep
);

`RESET_RESYNC // Reset pipelining

localparam int STR_BYTES     = $bits(german_str_t) / 8;
localparam int STRS_PER_BEAT = DATABEAT_SIZE / STR_BYTES;

`ASSERT_ELAB(DATABEAT_SIZE % STR_BYTES == 0)

ndata_i #(data8_t, DATABEAT_SIZE + EXTEND_WIDTH) in_ahead(clk, reset_synced);
NDataLookahead #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .PREVIEW_SIZE(EXTEND_WIDTH)
) inst_lookahead (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_data),
    .out(in_ahead)
);

data_i #(length_beat_t) lengths(clk, reset_synced);
LengthExtractor #(
    .BEAT_WIDTH(DATABEAT_SIZE),
    .EXTEND_WIDTH(EXTEND_WIDTH),
    .N(N)
) inst_length_extractor (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_ahead),
    .out(lengths)
);

ndata_i #(german_str_t, N) string_lanes(clk, reset_synced);
GermanStringBuilder #(
    .BEAT_WIDTH(DATABEAT_SIZE),
    .EXTEND_WIDTH(EXTEND_WIDTH),
    .N(N)
) inst_german_string_builder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(conf),
    .in(lengths),

    .out_strings(string_lanes),
    .out_heap(out_heap)
);

// Beats with fewer than N strings are packed into full beats
ndata_i #(german_str_t, N) strings_packed(clk, reset_synced);
DataNormalizer #(
    .data_t(german_str_t),
    .NUM_ELEMENTS(N)
) inst_strings_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(string_lanes),
    .out(strings_packed)
);

// A page that ends in heap bytes ends with a beat without strings, whose last moves to the previous
// beat
ndata_i #(german_str_t, N) strings_suppressed(clk, reset_synced);
NullBeatSuppressor #(
    .data_t(german_str_t),
    .NUM_ELEMENTS(N)
) inst_strings_suppressor (
    .clk(clk),
    .rst_n(reset_synced),

    .in(strings_packed),
    .out(strings_suppressed)
);

ndata_i #(german_str_t, STRS_PER_BEAT) strings(clk, reset_synced);
NDataWidthConverter #(german_str_t) inst_strings_width_converter (
    .clk(clk),
    .rst_n(reset_synced),

    .in(strings_suppressed),
    .out(strings)
);

for (genvar I = 0; I < STRS_PER_BEAT; I++) begin
    for (genvar J = 0; J < STR_BYTES; J++) begin
        assign out_strings.data[I * STR_BYTES + J] = strings.data[I][J * 8+:8];
        assign out_strings.keep[I * STR_BYTES + J] = strings.keep[I];
    end
end
assign out_strings.last  = strings.last;
assign out_strings.valid = strings.valid;
assign strings.ready     = out_strings.ready;

endmodule
