`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;
import parcore_string::*;

// Finds the length prefixes of a PLAIN encoded string page and extracts up to 4 strings per cycle.
//
// Which bytes are prefixes depends on all prefixes before them, so they form a chain. To follow the
// chain for 4 prefixes in one cycle, a table stores for every byte where the next prefix would be if
// that byte was a prefix, and where the prefix after that would be. A beat with more prefixes than
// fit into a cycle is repeated with duplicate set.
module LengthExtractor #(
    parameter int BEAT_WIDTH   = STRING_BEAT_WIDTH,
    parameter int EXTEND_WIDTH = STRING_EXTEND_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data8_t, BEAT_WIDTH + EXTEND_WIDTH)
    data_i.m  out // #(length_beat_t)
);

`RESET_RESYNC // Reset pipelining

localparam int VIEW_WIDTH   = BEAT_WIDTH + EXTEND_WIDTH;
localparam int PREFIX_BYTES = STRING_PREFIX_BYTES;
localparam int INLINE_BYTES = STRING_INLINE_BYTES;
localparam int POS_BITS     = $clog2(BEAT_WIDTH);

`ASSERT_ELAB(EXTEND_WIDTH >= PREFIX_BYTES + INLINE_BYTES - 1)
`ASSERT_ELAB(2 ** POS_BITS == BEAT_WIDTH && POS_BITS < 8)
`ASSERT_ELAB(in.NUM_ELEMENTS == VIEW_WIDTH)
`ASSERT_ELAB(BEAT_WIDTH == STRING_BEAT_WIDTH && EXTEND_WIDTH == STRING_EXTEND_WIDTH)

typedef logic[POS_BITS - 1:0]      pos_t;   // Offset within the beat
typedef logic[POS_BITS + 1:0]      sum_t;   // Offset plus prefix plus the low bits of a length
typedef logic[32 - POS_BITS - 1:0] beats_t; // Number of beats

// Where the chain continues after a length prefix:
// - in_beat set, pos >= PREFIX_BYTES: at pos of this beat
// - in_beat not set:                  at pos of the next beat
// - in_beat set, pos < PREFIX_BYTES:  past the next beat. A hop cannot end this early in a beat.
typedef struct packed {
    logic in_beat;
    pos_t pos;
} ptr_t;

typedef logic[POS_BITS:0] count_t; // Number of valid bytes of a beat

typedef struct packed {
    data8_t[VIEW_WIDTH - 1:0] data;
    count_t                   count;
    logic                     last;
    ptr_t  [BEAT_WIDTH - 1:0] next; // One hop from each byte
} first_beat_t;

typedef struct packed {
    data8_t[VIEW_WIDTH - 1:0] data;
    count_t                   count;
    logic                     last;
    ptr_t  [BEAT_WIDTH - 1:0] next;  // One hop from each byte
    ptr_t  [BEAT_WIDTH - 1:0] next2; // Two hops from each byte, if the first hop stays in the beat
    logic  [BEAT_WIDTH - 1:0] two_hops_stay; // Two hops from each byte stay in the beat
} table_beat_t;

typedef struct packed {
    data8_t[VIEW_WIDTH - 1:0]        data;
    count_t                          count;
    logic                            last;
    logic                            duplicate;
    pos_t  [STRINGS_PER_CYCLE - 1:0] positions;
    logic  [STRINGS_PER_CYCLE - 1:0] length_keep;
} position_beat_t;

// The length prefix and the inline bytes after it
typedef data8_t[PREFIX_BYTES + INLINE_BYTES - 1:0] window_t;

// The bytes at pos with one shifter, so the bytes of a window share their multiplexers
function automatic window_t read_window(data8_t[VIEW_WIDTH - 1:0] data, pos_t pos);
    for (int i = POS_BITS - 1; i >= 0; i--) begin
        if (pos[i]) begin
            data = data >> (8 * 2 ** i);
        end
    end
    return window_t'(data);
endfunction

// The bytes of a beat are consecutive, as positions are counted in full beats
function automatic count_t count_bytes(logic[BEAT_WIDTH - 1:0] keep);
    pos_t last_pos;

    last_pos = '0;
    for (int i = POS_BITS - 1; i >= 0; i--) begin
        if (keep[int'(last_pos) + 2 ** i]) begin
            last_pos += 2 ** i;
        end
    end
    return keep[last_pos] ? count_t'(last_pos) + 1 : '0;
endfunction

function automatic logic stays_in_beat(ptr_t hop);
    return hop.in_beat && hop.pos >= PREFIX_BYTES;
endfunction

// ------- Table ---------
first_beat_t table_first;
table_beat_t table_beat, table_beat_next;
logic        table_valid;

data_i #(first_beat_t) to_table(clk, reset_synced), table_in(clk, reset_synced);

(* max_fanout = 64 *) logic table_enable;

always_comb begin
    // The bytes without keep are undefined in the last beat, so they are not used for the chain
    data8_t[BEAT_WIDTH + PREFIX_BYTES - 2:0] table_data;
    logic[BEAT_WIDTH + PREFIX_BYTES - 2:0]   byte_zero;

    for (int i = 0; i < BEAT_WIDTH + PREFIX_BYTES - 1; i++) begin
        table_data[i] = in.keep[i] ? in.data[i] : '0;
        byte_zero[i]  = table_data[i] == '0;
    end

    table_first.data  = in.data;
    table_first.count = count_bytes(in.keep[BEAT_WIDTH - 1:0]);
    table_first.last  = in.last;

    // Only the low bits of a length are added. The other bits only say that the chain leaves the beat.
    for (int b = 0; b < BEAT_WIDTH; b++) begin
        sum_t sum;
        logic upper_zero, past_next_beat;

        sum            = sum_t'(b) + PREFIX_BYTES + table_data[b][POS_BITS - 1:0];
        upper_zero     = byte_zero[b + 1] && byte_zero[b + 2] && byte_zero[b + 3];
        past_next_beat = !upper_zero || (table_data[b] >> (POS_BITS + 1)) != '0 || sum[POS_BITS + 1] ||
                         (table_data[b][POS_BITS] && sum[POS_BITS]);

        table_first.next[b].in_beat = past_next_beat || (!table_data[b][POS_BITS] && !sum[POS_BITS]);
        table_first.next[b].pos     = past_next_beat ? '0 : sum[POS_BITS - 1:0];
    end
end

assign to_table.data  = table_first;
assign to_table.keep  = 1'b1;
assign to_table.last  = in.last;
assign to_table.valid = in.valid;
assign in.ready       = to_table.ready;

DataSkidBuffer #(first_beat_t) inst_table_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(to_table),
    .out(table_in)
);

// A hop moves at least PREFIX_BYTES forward, so each byte only selects from the bytes after that.
// next2 is not used if the first hop leaves the beat, which is outside of reachable.
for (genvar B = 0; B < BEAT_WIDTH; B++) begin : gen_next2
    if (B + PREFIX_BYTES < BEAT_WIDTH) begin : gen_reachable
        ptr_t[BEAT_WIDTH - 1:B + PREFIX_BYTES] reachable;

        assign reachable                = table_in.data.next[BEAT_WIDTH - 1:B + PREFIX_BYTES];
        assign table_beat_next.next2[B] = reachable[table_in.data.next[B].pos];
    end else begin : gen_unreachable
        assign table_beat_next.next2[B] = '0;
    end
end

// Whether a beat is repeated decides the enable of all registers before it, so it is read with two
// lookups instead of following the chain.
for (genvar B = 0; B < BEAT_WIDTH; B++) begin : gen_hops_stay
    assign table_beat_next.two_hops_stay[B] = stays_in_beat(table_in.data.next[B]) &&
                                              stays_in_beat(table_beat_next.next2[B]);
end

assign table_beat_next.data  = table_in.data.data;
assign table_beat_next.count = table_in.data.count;
assign table_beat_next.last  = table_in.data.last;
assign table_beat_next.next  = table_in.data.next;

always_ff @(posedge clk) begin
    if (table_enable) begin
        table_beat <= table_beat_next;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        table_valid <= 1'b0;
    end else if (table_enable) begin
        table_valid <= table_in.valid;
    end
end

assign table_in.ready = table_enable;

// ------- Follow the chain ---------
table_beat_t cur;
pos_t        cursor;
logic        skipping;   // The cursor is past this beat
logic        load_skip;  // skipping was just set, so skip_beats is loaded from the length
beats_t      skip_beats; // Beats left to skip after this one

logic           enable;
position_beat_t positions, positions_next;
logic           positions_valid;
logic           length_valid;

ptr_t      hop1, hop2, hop3, hop4, leave;
logic[STRINGS_PER_CYCLE:0] found;
logic      repeat_beat;

assign cur = table_beat;

assign hop1 = cur.next[cursor];
assign hop2 = cur.next2[cursor];
assign hop3 = cur.next[hop2.pos];
assign hop4 = cur.next2[hop2.pos];

// The hops of the last beat can end in invalid bytes. These are removed when reading the lengths and
// at most repeat the last beat once, as the cursor then is outside of the valid bytes.
assign found[0] = !skipping && count_t'(cursor) < cur.count;
assign found[1] = found[0] && stays_in_beat(hop1);
assign found[2] = found[1] && stays_in_beat(hop2);
assign found[3] = found[2] && stays_in_beat(hop3);
assign found[4] = found[0] && cur.two_hops_stay[cursor] && cur.two_hops_stay[hop2.pos];

// More than 4 length prefixes in this beat, so it is processed again in the next cycle
assign repeat_beat = table_valid && found[4];
assign leave       = found[3] ? hop4 : found[2] ? hop3 : found[1] ? hop2 : hop1;

assign enable       = !length_valid || out.ready;
assign table_enable = !table_valid || (enable && !repeat_beat);

always_comb begin
    positions_next.data         = cur.data;
    positions_next.count        = cur.count;
    positions_next.last         = cur.last && !repeat_beat;
    positions_next.duplicate    = repeat_beat;
    positions_next.length_keep  = found[STRINGS_PER_CYCLE - 1:0];
    positions_next.positions[0] = found[0] ? cursor   : '0;
    positions_next.positions[1] = found[1] ? hop1.pos : '0;
    positions_next.positions[2] = found[2] ? hop2.pos : '0;
    positions_next.positions[3] = found[3] ? hop3.pos : '0;
end

always_ff @(posedge clk) begin
    if (enable) begin
        positions <= positions_next;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        positions_valid <= 1'b0;
    end else if (enable) begin
        positions_valid <= table_valid;
    end
end

// ------- Read the lengths ---------
length_beat_t                     length_beat;
logic                             length_last;
window_t[STRINGS_PER_CYCLE - 1:0] windows;

for (genvar I = 0; I < STRINGS_PER_CYCLE; I++) begin : gen_windows
    assign windows[I] = read_window(positions.data, positions.positions[I]);
end

always_ff @(posedge clk) begin
    if (enable) begin
        length_beat.data        <= positions.data[BEAT_WIDTH - 1:0];
        length_beat.positions   <= positions.positions;
        length_beat.duplicate   <= positions.duplicate;
        length_last             <= positions.last;
        for (int i = 0; i < STRINGS_PER_CYCLE; i++) begin
            length_beat.length_keep[i]  <= positions.length_keep[i] &&
                                           count_t'(positions.positions[i]) < positions.count;
            length_beat.lengths[i]      <= data32_t'(windows[i]);
            length_beat.inline_bytes[i] <= windows[i][PREFIX_BYTES + INLINE_BYTES - 1:PREFIX_BYTES];
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        length_valid <= 1'b0;
    end else if (enable) begin
        length_valid <= positions_valid;
    end
end

assign out.data  = length_beat;
assign out.keep  = 1'b1;
assign out.last  = length_last;
assign out.valid = length_valid;

// ------- Move the cursor ---------
// A string that reaches past the next beat is only known to do so when its beat is taken. Its length
// arrives one cycle later, while the next beat is skipped.
data32_t          leaving_length;
pos_t             leaving_pos;
sum_t             leaving_sum;
logic signed[2:0] skip_change;
beats_t           skip_beats_next;

always_comb begin
    int lane;

    lane = positions.length_keep[3] ? 3 : positions.length_keep[2] ? 2 : positions.length_keep[1] ? 1 : 0;

    leaving_length = data32_t'(windows[lane]);
    leaving_pos    = positions.positions[lane];
    leaving_sum    = sum_t'(leaving_pos) + PREFIX_BYTES + leaving_length[POS_BITS - 1:0];

    skip_change = load_skip ? $signed(3'(leaving_sum[POS_BITS + 1:POS_BITS])) - 3'sd1 : 3'sd0;
    if (table_valid) begin
        skip_change = skip_change - 3'sd1;
    end

    skip_beats_next = (load_skip ? leaving_length[31:POS_BITS] : skip_beats) + beats_t'(skip_change);
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        cursor    <= '0;
        skipping  <= 1'b0;
        load_skip <= 1'b0;
    end else if (enable) begin
        load_skip <= 1'b0;

        if (table_valid && cur.last && !found[4]) begin
            cursor   <= '0;
            skipping <= 1'b0;
        end else if (skipping) begin
            skip_beats <= skip_beats_next;
            skipping   <= skip_beats_next != '0;
            if (load_skip) begin
                cursor <= leaving_sum[POS_BITS - 1:0];
            end
        end else if (table_valid && found[0]) begin
            cursor <= leave.pos;
            if (leave.in_beat && leave.pos < PREFIX_BYTES) begin
                skipping  <= 1'b1;
                load_skip <= 1'b1;
            end
        end
    end
end

endmodule
