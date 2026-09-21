`timescale 1ns / 1ps

`include "libstf_macros.svh"
`include "lynx_macros.svh"

import lynxTypes::*;
import libstf::data8_t;
import libstf::data32_t;
import parcore::*;

/**
 * This module strips the repetition and definition levels from the start of a
 * page and emits a normalized stream.
 *
 * When the page carries levels it starts with a 4-byte length prefix followed
 * by that many level bytes, i.e. the first `NUM_BYTES_OFFSET + <prefix>` bytes
 * are levels that have to be discarded. Because everything after the header is
 * dense, the only mismatch between input and output beats is a single, constant
 * byte shift `h` (the header length modulo NUM_BYTES). This module therefore
 * works like a `DataNormalizer`, but instead of an accumulating per-beat offset
 * it uses a single, fixed barrel-shifter offset derived from the header length
 * and merges the wrapped bytes across beats in an output register.
 *
 * A page from a REQUIRED Parquet column (max_definition_level == 0 and
 * max_repetition_level == 0) has no levels and therefore no length prefix: its
 * body is values only. Such a page must pass through untouched, which the
 * `levels` stream signals per page. Stripping it anyway would consume
 * `4 + <first four value bytes read as a length>` bytes of real data, and the
 * resulting short stream makes TypedNormalizeUntil swallow the chunk's `last`
 * (see the assertion there).
 */
module StripLevels #(
    parameter NUM_BYTES = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s levels,  // #(logic)

    ndata_i.s in,            // #(data8_t, NUM_BYTES)
    ndata_i.m out            // #(data8_t, NUM_BYTES)
);

`RESET_RESYNC // Reset pipelining

localparam int NUM_BYTES_OFFSET = 4;
localparam int OFFSET_WIDTH = $clog2(NUM_BYTES);

localparam int HEADER_OFFSET_WIDTH = 32 + 1;
typedef logic [HEADER_OFFSET_WIDTH - 1:0] header_offset_t;

ndata_i #(data8_t, NUM_BYTES) out_inner(clk, reset_synced);

// ------- Header-stripping front end -------------
// `remaining_offset` counts how many header bytes still have to be discarded. While 
// `remaining_offset >= NUM_BYTES`, whole input beats are dropped. The final, partial header beat 
// has its leading `remaining_offset` bytes masked out of `keep` and feeds the barrel shifter, which 
// rotates the remaining data so it becomes front-packed.
typedef enum logic[1:0] {
    ST_WAIT,    // Reading the length prefix of a new page
    ST_CONSUME, // Dropping whole beats while remaining_offset >= NUM_BYTES
    ST_PIPE     // Forwarding (masked) beats into the normalizer
} state_t;
state_t state;
header_offset_t remaining_offset, remaining_offset_succ;
logic[OFFSET_WIDTH - 1:0] shift_offset;

assign remaining_offset_succ = remaining_offset - NUM_BYTES;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        remaining_offset <= 'X;
        shift_offset     <= 'X;
        state            <= ST_WAIT;
    end else begin
        case (state)
            ST_WAIT: begin
                if (in.valid && levels.valid) begin
                    // 4 prefix bytes + the level length encoded in those bytes,
                    // or nothing at all when this page carries no levels.
                    automatic header_offset_t actual_offset =
                        levels.data ? (NUM_BYTES_OFFSET + in.data[NUM_BYTES_OFFSET - 1:0]) : '0;

                    remaining_offset <= actual_offset;
                    shift_offset     <= (NUM_BYTES - actual_offset[OFFSET_WIDTH - 1:0]) % NUM_BYTES;
                    state            <= (actual_offset >= NUM_BYTES) ? ST_CONSUME : ST_PIPE;
                end
            end
            ST_CONSUME: begin
                if (in.valid) begin
                    remaining_offset <= remaining_offset_succ;

                    if (remaining_offset_succ < NUM_BYTES) begin
                        state <= ST_PIPE;
                    end
                end
            end
            ST_PIPE: begin
                if (in.ready && in.valid) begin
                    remaining_offset <= 0;

                    if (in.last) begin
                        state <= ST_WAIT;
                    end
                end
            end
        endcase
    end
end

assign in.ready = (state == ST_CONSUME) || (state == ST_PIPE && shifter_in.ready);

// The first beat of a page is held (not consumed) while ST_WAIT samples the
// prefix, so the page's `levels` beat retires on the cycle we leave ST_WAIT.
// Contract: every page owes exactly one `levels` beat, and a page is expected
// to carry at least one payload beat -- an empty page would leave both this
// stream and the page's `last` outstanding.
assign levels.ready = (state == ST_WAIT) && in.valid;

// ------- Masking + barrel shifter ---------------
ndata_i #(data8_t, NUM_BYTES) shifter_in(clk, reset_synced), shifter_out(clk, reset_synced);

assign shifter_in.data  = in.data;
assign shifter_in.keep  = in.keep & ({NUM_BYTES{1'b1}} << remaining_offset[OFFSET_WIDTH - 1:0]);
assign shifter_in.last  = in.last;
assign shifter_in.valid = (state == ST_PIPE) && in.valid;

BarrelShifter #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_BYTES),
    .REGISTER_LEVELS(1)
) inst_barrel_shifter (
    .clk(clk),
    .rst_n(reset_synced),

    .offset(shift_offset),

    .in(shifter_in),
    .out(shifter_out)
);

// ------- Cross-beat merge (output register) -----
DataBeatMerge #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_BYTES)
) inst_merge (
    .clk(clk),
    .rst_n(reset_synced),

    .in(shifter_out),
    .out(out_inner)
);

NDataSkidBuffer #(data8_t, NUM_BYTES) inst_skid_buffer_out (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_inner),
    .out(out)
);

endmodule
