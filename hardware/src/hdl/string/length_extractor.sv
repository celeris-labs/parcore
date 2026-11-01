`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;
import parcore_string::*;

// Finds the length prefixes of a PLAIN encoded string page and extracts up to N lengths and their
// positions per cycle. See docs/strings/length_extractor.md.
module LengthExtractor #(
    parameter int BEAT_WIDTH   = STRING_BEAT_WIDTH,
    parameter int EXTEND_WIDTH = STRING_EXTEND_WIDTH,
    parameter int N            = STRING_N
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data8_t, BEAT_WIDTH + EXTEND_WIDTH)
    data_i.m  out // #(length_beat_t)
);

`RESET_RESYNC // Reset pipelining

localparam int VIEW_WIDTH    = BEAT_WIDTH + EXTEND_WIDTH;
localparam int PREFIX_BYTES  = 4;
localparam int POS_BITS      = $clog2(BEAT_WIDTH);
localparam int NUM_PRE_STEPS = $clog2(N) + 1;

`ASSERT_ELAB(EXTEND_WIDTH >= PREFIX_BYTES - 1)
`ASSERT_ELAB(N >= 1 && 2 ** $clog2(N) == N)
`ASSERT_ELAB(in.NUM_ELEMENTS == VIEW_WIDTH)
`ASSERT_ELAB(BEAT_WIDTH == STRING_BEAT_WIDTH && EXTEND_WIDTH == STRING_EXTEND_WIDTH && N == STRING_N)

typedef logic[POS_BITS - 1:0] pos_t;  // Offset within the beat
typedef logic[32:0]           dist_t; // Byte distance from the start of the beat

// A position in the chain of length prefixes. pos is only meaningful if in_beat is set, except for
// jump, where pos is the last length prefix in the beat if in_beat is not set.
typedef struct packed {
    logic in_beat;
    pos_t pos;
} ptr_t;

// Jump here denotes the cursor position of the length prefix, the cursor would jump to
// after parsing N length prefixes
typedef struct packed {
    data8_t[VIEW_WIDTH - 1:0] data;
    logic  [VIEW_WIDTH - 1:0] keep;
    logic                     last;
    ptr_t  [BEAT_WIDTH - 1:0] next;
    ptr_t  [BEAT_WIDTH - 1:0] jump;
} pre_beat_t;

typedef struct packed {
    data8_t [VIEW_WIDTH - 1:0] data;
    logic   [VIEW_WIDTH - 1:0] keep;
    logic                      last;
    logic                      duplicate; // Whether this beat contains the same data
                                          // as the previous beat. This can be the case
                                          // if there are more then N length prefixes in a
                                          // single beat
    ptr_t   [BEAT_WIDTH - 1:0] next;
    ptr_t                      sub;
    data32_t[N - 1:0]          lengths;
    pos_t   [N - 1:0]          positions;
    logic   [N - 1:0]          length_keep;
} ext_beat_t;

function automatic data32_t read_length(data8_t[VIEW_WIDTH - 1:0] data, pos_t pos);
    for (int i = 0; i < PREFIX_BYTES; i++) begin
        read_length[i * 8+:8] = data[int'(pos) + i];
    end
endfunction

// ------- Preprocessing ---------
pre_beat_t pre      [NUM_PRE_STEPS];
logic      pre_valid[NUM_PRE_STEPS];
pre_beat_t pre_first;

data_i #(pre_beat_t) to_extraction(clk, reset_synced), extraction_in(clk, reset_synced);

logic pre_enable;
assign pre_enable = !pre_valid[NUM_PRE_STEPS - 1] || to_extraction.ready;

always_comb begin
    pre_first.data = in.data;
    pre_first.keep = in.keep;
    pre_first.last = in.last;

    for (int b = 0; b < BEAT_WIDTH; b++) begin
        dist_t next;
        logic  next_in_beat;

        next = dist_t'(b) + PREFIX_BYTES + read_length(in.data, pos_t'(b));
        next_in_beat = next < BEAT_WIDTH && in.keep[next[POS_BITS - 1:0]];

        pre_first.next[b]      = ptr_t'{in_beat: next_in_beat, pos: next[POS_BITS - 1:0]};
        pre_first.jump[b]      = next_in_beat ? pre_first.next[b] : ptr_t'{in_beat: 1'b0, pos: pos_t'(b)};
    end
end

always_ff @(posedge clk) begin
    if (pre_enable) begin
        pre[0] <= pre_first;
    end
end

// Each step doubles the number of hops of jump
for (genvar S = 1; S < NUM_PRE_STEPS; S++) begin : gen_pre_steps
    // A hop moves at least PREFIX_BYTES forward, so an in-beat jump of byte B points to
    // B + MIN_DISTANCE or later. Each byte only selects from these bytes.
    localparam int MIN_DISTANCE = PREFIX_BYTES * 2 ** (S - 1);

    pre_beat_t              doubled;
    ptr_t[BEAT_WIDTH - 1:0] doubled_jump;

    for (genvar B = 0; B < BEAT_WIDTH; B++) begin : gen_bytes
        if (B + MIN_DISTANCE < BEAT_WIDTH) begin : gen_reachable
            ptr_t[BEAT_WIDTH - 1:B + MIN_DISTANCE] reachable;

            assign reachable       = pre[S - 1].jump[BEAT_WIDTH - 1:B + MIN_DISTANCE];
            assign doubled_jump[B] = pre[S - 1].jump[B].in_beat ? reachable[pre[S - 1].jump[B].pos] :
                                                                   pre[S - 1].jump[B];
        end else begin : gen_unreachable
            assign doubled_jump[B] = pre[S - 1].jump[B];
        end
    end

    always_comb begin
        doubled      = pre[S - 1];
        doubled.jump = doubled_jump;
    end

    always_ff @(posedge clk) begin
        if (pre_enable) begin
            pre[S] <= doubled;
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        for (int s = 0; s < NUM_PRE_STEPS; s++) begin
            pre_valid[s] <= 1'b0;
        end
    end else if (pre_enable) begin
        pre_valid[0] <= in.valid;
        for (int s = 1; s < NUM_PRE_STEPS; s++) begin
            pre_valid[s] <= pre_valid[s - 1];
        end
    end
end

assign in.ready = pre_enable;

assign to_extraction.data  = pre[NUM_PRE_STEPS - 1];
assign to_extraction.keep  = 1'b1;
assign to_extraction.last  = pre[NUM_PRE_STEPS - 1].last;
assign to_extraction.valid = pre_valid[NUM_PRE_STEPS - 1];

DataSkidBuffer #(pre_beat_t) inst_pre_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(to_extraction),
    .out(extraction_in)
);

// ------- Extraction ---------
ext_beat_t ext      [N];
logic      ext_valid[N];
ext_beat_t ext_first;

data_i #(length_beat_t) to_out(clk, reset_synced);

pre_beat_t cur;
dist_t     cursor, next_cursor;
logic      cursor_in_beat, repeat_beat;
pos_t      cursor_pos;
ptr_t      cursor_jump;

logic ext_enable;
assign ext_enable = !ext_valid[N - 1] || to_out.ready;

assign cur            = extraction_in.data;
assign cursor_pos     = cursor[POS_BITS - 1:0];
assign cursor_in_beat = cursor < BEAT_WIDTH && cur.keep[cursor_pos];
assign cursor_jump    = cur.jump[cursor_pos];
// More than N length prefixes in this beat, so it is processed again in the next cycle
assign repeat_beat    = extraction_in.valid && cursor_in_beat && cursor_jump.in_beat;

always_comb begin
    if (cur.last && !repeat_beat) begin
        next_cursor = '0;
    end else if (cursor >= BEAT_WIDTH) begin
        next_cursor = cursor - BEAT_WIDTH;
    end else if (cursor_jump.in_beat) begin
        next_cursor = dist_t'(cursor_jump.pos);
    end else begin
        // The chain leaves the beat after the length prefix at cursor_jump.pos
        next_cursor = dist_t'(read_length(cur.data, cursor_jump.pos)) + cursor_jump.pos + PREFIX_BYTES
                    - BEAT_WIDTH;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        cursor <= '0;
    end else if (ext_enable && extraction_in.valid) begin
        cursor <= next_cursor;
    end
end

assign extraction_in.ready = ext_enable && !repeat_beat;

always_comb begin
    ext_first = '0;

    ext_first.data      = cur.data;
    ext_first.keep      = cur.keep;
    ext_first.last      = cur.last && !repeat_beat;
    ext_first.duplicate = repeat_beat;
    ext_first.next      = cur.next;

    ext_first.lengths[0]     = read_length(cur.data, cursor_pos);
    ext_first.positions[0]   = cursor_pos;
    ext_first.length_keep[0] = cursor_in_beat;
    ext_first.sub            = cursor_in_beat ? cur.next[cursor_pos] : '0;
end

always_ff @(posedge clk) begin
    if (ext_enable) begin
        ext[0] <= ext_first;
    end
end

// Each step extracts the length prefix at the subcursor and moves the subcursor to its next
for (genvar S = 1; S < N; S++) begin : gen_ext_steps
    ext_beat_t extracted;

    always_comb begin
        extracted = ext[S - 1];

        extracted.lengths[S]     = read_length(ext[S - 1].data, ext[S - 1].sub.pos);
        extracted.positions[S]   = ext[S - 1].sub.pos;
        extracted.length_keep[S] = ext[S - 1].sub.in_beat;
        if (ext[S - 1].sub.in_beat) begin
            extracted.sub = ext[S - 1].next[ext[S - 1].sub.pos];
        end
    end

    always_ff @(posedge clk) begin
        if (ext_enable) begin
            ext[S] <= extracted;
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        for (int s = 0; s < N; s++) begin
            ext_valid[s] <= 1'b0;
        end
    end else if (ext_enable) begin
        ext_valid[0] <= extraction_in.valid;
        for (int s = 1; s < N; s++) begin
            ext_valid[s] <= ext_valid[s - 1];
        end
    end
end

assign to_out.data.data        = ext[N - 1].data;
assign to_out.data.data_keep   = ext[N - 1].keep;
assign to_out.data.lengths     = ext[N - 1].lengths;
assign to_out.data.positions   = ext[N - 1].positions;
assign to_out.data.length_keep = ext[N - 1].length_keep;
assign to_out.data.duplicate   = ext[N - 1].duplicate;
assign to_out.keep             = 1'b1;
assign to_out.last             = ext[N - 1].last;
assign to_out.valid            = ext_valid[N - 1];

DataSkidBuffer #(length_beat_t) inst_out_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(to_out),
    .out(out)
);

endmodule
