`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;
import parcore_string::*;

// Builds the german strings of a PLAIN encoded string page from the output of the LengthExtractor
// and marks the heap bytes.
// Lengths and short strings are remove from the heap to reduce heap overhead.
module GermanStringBuilder #(
    parameter int BEAT_WIDTH   = STRING_BEAT_WIDTH,
    parameter int EXTEND_WIDTH = STRING_EXTEND_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,        // #(string_decoder_conf_t)
    data_i.s        in,          // #(length_beat_t)

    ndata_i.m       out_strings, // #(german_str_t, STRINGS_PER_CYCLE)
    ndata_i.m       out_heap     // #(data8_t, BEAT_WIDTH)
);

`RESET_RESYNC // Reset pipelining

localparam int PREFIX_BYTES = STRING_PREFIX_BYTES;
localparam int INLINE_BYTES = STRING_INLINE_BYTES;
localparam int POS_BITS     = $clog2(BEAT_WIDTH);

`ASSERT_ELAB(EXTEND_WIDTH >= PREFIX_BYTES + INLINE_BYTES - 1)
`ASSERT_ELAB(BEAT_WIDTH == STRING_BEAT_WIDTH && EXTEND_WIDTH == STRING_EXTEND_WIDTH)

typedef logic[POS_BITS - 1:0] pos_t;
typedef logic[POS_BITS:0]     off_t;  // Offset within a beat or just past it
typedef logic[32:0]           dist_t; // Byte distance from the start of a beat
typedef logic[63:0]           addr_t;
typedef logic[BEAT_WIDTH - 1:0] beat_keep_t;

typedef struct packed {
    logic                         valid;
    logic                         is_long;     // asserted when strings is long,
                                               // deasserted for anything else,
                                               // such as short strings or invalid strings 
    data32_t                      length;
    data8_t [INLINE_BYTES - 1:0]  bytes;       // The first bytes of the string, 0 beyond length
    off_t                         heap_start;  // Heap bytes of a long string in this beat:
    off_t                         heap_end;    // [heap_start, heap_end)
    off_t                         small_len;   // Length of a long string that ends in this beat
    logic                         beyond;      // Long string whose payload extends past the beat
    off_t                         carry_start; // Payload past the beat, relative to the next beat:
    dist_t                        carry_end;   // [carry_start, carry_end)
} lane_t;

typedef struct packed {
    data8_t[BEAT_WIDTH - 1:0] data;
    logic                     last;
    logic                     duplicate;  // denotes if this beat repeats the
                                          // heap from the previous beat.
                                          // This can happen when more than 4 strings
                                          // are in the beat
    logic                     page_first;
    string_decoder_conf_t     conf;
} beat_info_t;

// Bytes [lo, hi) of a beat
function automatic beat_keep_t byte_range(off_t lo, off_t hi);
    for (int j = 0; j < BEAT_WIDTH; j++) begin
        byte_range[j] = j >= lo && j < hi;
    end
endfunction

// ------- Input ---------
length_beat_t in_beat;
logic         enable;
logic         page_first;

assign in_beat = in.data;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        page_first <= 1'b1;
    end else if (in.valid && in.ready) begin
        page_first <= in.last;
    end
end

// The configuration of a page is taken with its first beat
assign in.ready   = enable && (!page_first || conf.valid);
assign conf.ready = enable && in.valid && page_first;

// ------- Stage 1: Strings and heap ranges per lane ---------
lane_t     [STRINGS_PER_CYCLE - 1:0] lanes_1, lanes_1_next;
beat_info_t                         info_1;
logic                               valid_1;

always_comb begin
    for (int i = 0; i < STRINGS_PER_CYCLE; i++) begin
        pos_t  pos;
        dist_t end_pos;
        logic  length_fits; // Length is below 16, so inline bytes past it are compared

        pos         = in_beat.positions[i];
        end_pos     = dist_t'(pos) + PREFIX_BYTES + in_beat.lengths[i];
        length_fits = in_beat.lengths[i][31:4] == '0;

        lanes_1_next[i].valid   = in_beat.length_keep[i];
        lanes_1_next[i].length  = in_beat.lengths[i];
        lanes_1_next[i].is_long = in_beat.length_keep[i] &&
                                  (!length_fits || in_beat.lengths[i][3:0] > INLINE_BYTES);
        for (int k = 0; k < INLINE_BYTES; k++) begin
            lanes_1_next[i].bytes[k] = !length_fits || k < in_beat.lengths[i][3:0] ?
                                       in_beat.inline_bytes[i][k] : '0;
        end

        lanes_1_next[i].beyond      = lanes_1_next[i].is_long && end_pos > BEAT_WIDTH;
        lanes_1_next[i].heap_start  = off_t'(pos) + PREFIX_BYTES;
        lanes_1_next[i].heap_end    = lanes_1_next[i].beyond ? off_t'(BEAT_WIDTH) : off_t'(end_pos);
        lanes_1_next[i].small_len   = lanes_1_next[i].is_long && !lanes_1_next[i].beyond ?
                                      off_t'(in_beat.lengths[i]) : '0;
        lanes_1_next[i].carry_start = lanes_1_next[i].heap_start > BEAT_WIDTH ?
                                      lanes_1_next[i].heap_start - BEAT_WIDTH : '0;
        lanes_1_next[i].carry_end   = end_pos - BEAT_WIDTH;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_1 <= 1'b0;
    end else if (enable) begin
        valid_1 <= in.valid && in.ready;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        lanes_1                <= lanes_1_next;
        info_1.data            <= in_beat.data;
        info_1.last            <= in.last;
        info_1.duplicate       <= in_beat.duplicate;
        info_1.page_first      <= page_first;
        info_1.conf            <= conf.data;
    end
end

// ------- Stage 2: Heap keep and address offsets of the beat ---------
lane_t     [STRINGS_PER_CYCLE - 1:0] lanes_2;
beat_info_t                         info_2;
logic                               valid_2;
beat_keep_t                         keep_2, keep_2_next;
off_t      [STRINGS_PER_CYCLE - 1:0] offsets_2, offsets_2_next; // Long lengths of the lanes before
dist_t                              total_2, total_2_next;     // Long lengths of all lanes
logic                               beyond_2, beyond_2_next;
off_t                               carry_start_2, carry_start_2_next;
dist_t                              carry_end_2, carry_end_2_next;

always_comb begin
    off_t small_sum;

    keep_2_next        = '0;
    small_sum          = '0;
    total_2_next       = '0;
    beyond_2_next      = 1'b0;
    carry_start_2_next = '0;
    carry_end_2_next   = '0;

    for (int i = 0; i < STRINGS_PER_CYCLE; i++) begin
        if (lanes_1[i].is_long) begin
            keep_2_next |= byte_range(lanes_1[i].heap_start, lanes_1[i].heap_end);
        end

        offsets_2_next[i] = small_sum;
        small_sum         = small_sum + lanes_1[i].small_len;

        // Only the last string of a beat can extend past it
        if (lanes_1[i].beyond) begin
            beyond_2_next      = 1'b1;
            total_2_next       = dist_t'(lanes_1[i].length);
            carry_start_2_next = lanes_1[i].carry_start;
            carry_end_2_next   = lanes_1[i].carry_end;
        end
    end

    total_2_next = total_2_next + small_sum;
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_2 <= 1'b0;
    end else if (enable) begin
        valid_2 <= valid_1;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        lanes_2       <= lanes_1;
        info_2        <= info_1;
        keep_2        <= keep_2_next;
        offsets_2     <= offsets_2_next;
        total_2       <= total_2_next;
        beyond_2      <= beyond_2_next;
        carry_start_2 <= carry_start_2_next;
        carry_end_2   <= carry_end_2_next;
    end
end

// ------- Stage 3: Heap address and heap keep across beats ---------
addr_t      heap_addr, base_addr;
beat_keep_t gathered_keep; // Heap keep of the duplicates of the current beat
off_t       carry_start;
dist_t      carry_end;
beat_keep_t carry_keep;

assign base_addr  = info_2.page_first && info_2.conf.update_buffer_addr ?
                    addr_t'(info_2.conf.buffer_addr) : heap_addr;
assign carry_keep = byte_range(carry_start, carry_end > BEAT_WIDTH ? off_t'(BEAT_WIDTH) : off_t'(carry_end));

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        heap_addr     <= '0;
        gathered_keep <= '0;
        carry_start   <= '0;
        carry_end     <= '0;
    end else if (enable && valid_2) begin
        heap_addr <= base_addr + total_2;

        if (info_2.duplicate) begin
            gathered_keep <= gathered_keep | keep_2;
        end else begin
            gathered_keep <= '0;

            if (info_2.last) begin
                carry_start <= '0;
                carry_end   <= '0;
            end else if (beyond_2) begin
                carry_start <= carry_start_2;
                carry_end   <= carry_end_2;
            end else begin
                carry_start <= '0;
                carry_end   <= carry_end > BEAT_WIDTH ? carry_end - BEAT_WIDTH : '0;
            end
        end
    end
end

ndata_i #(german_str_t, STRINGS_PER_CYCLE) strings_3(clk, reset_synced);
ndata_i #(data8_t, BEAT_WIDTH)             heap_3(clk, reset_synced);
german_str_t[STRINGS_PER_CYCLE - 1:0]      strings_3_next;
logic                                      valid_3;
logic                                      has_strings_3;
logic                                      duplicate_3;

always_comb begin
    for (int i = 0; i < STRINGS_PER_CYCLE; i++) begin
        addr_t addr;

        addr = base_addr + offsets_2[i];

        strings_3_next[i].length = lanes_2[i].length;
        for (int k = 0; k < PREFIX_BYTES; k++) begin
            strings_3_next[i].prefix[k] = lanes_2[i].bytes[k];
        end
        for (int k = 0; k < 8; k++) begin
            strings_3_next[i].short_str_or_addr[k] = lanes_2[i].is_long ? addr[k * 8+:8] :
                                                                         lanes_2[i].bytes[PREFIX_BYTES + k];
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_3 <= 1'b0;
    end else if (enable) begin
        valid_3 <= valid_2;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        for (int i = 0; i < STRINGS_PER_CYCLE; i++) begin
            strings_3.data[i] <= strings_3_next[i];
            strings_3.keep[i] <= lanes_2[i].valid;
        end
        strings_3.last <= info_2.last;
        has_strings_3  <= lanes_2[0].valid;

        heap_3.data    <= info_2.data;
        heap_3.keep    <= gathered_keep | keep_2 | carry_keep;
        heap_3.last    <= info_2.last;
        duplicate_3    <= info_2.duplicate;
    end
end

// ------- Output ---------
// Beats without strings produce no out_strings beat unless they carry last. Duplicates produce no
// out_heap beat.
assign strings_3.valid = valid_3 && (has_strings_3 || strings_3.last) && heap_3.ready;
assign heap_3.valid    = valid_3 && !duplicate_3 && strings_3.ready;
assign enable          = !valid_3 || (strings_3.ready && heap_3.ready);

NDataSkidBuffer #(german_str_t, STRINGS_PER_CYCLE) inst_strings_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(strings_3),
    .out(out_strings)
);

NDataSkidBuffer #(data8_t, BEAT_WIDTH) inst_heap_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(heap_3),
    .out(out_heap)
);

endmodule
