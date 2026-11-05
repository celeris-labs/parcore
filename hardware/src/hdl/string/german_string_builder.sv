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
    parameter int EXTEND_WIDTH = STRING_EXTEND_WIDTH,
    parameter int N            = STRING_N
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,        // #(plain_str_decoder_conf_t)
    data_i.s        in,          // #(length_beat_t)

    ndata_i.m       out_strings, // #(german_str_t, N)
    ndata_i.m       out_heap     // #(data8_t, BEAT_WIDTH)
);

`RESET_RESYNC // Reset pipelining

localparam int PREFIX_BYTES = STRING_PREFIX_BYTES;
localparam int INLINE_BYTES = STRING_INLINE_BYTES;
localparam int POS_BITS     = $clog2(BEAT_WIDTH);

`ASSERT_ELAB(EXTEND_WIDTH >= PREFIX_BYTES + INLINE_BYTES - 1)
`ASSERT_ELAB(BEAT_WIDTH == STRING_BEAT_WIDTH && EXTEND_WIDTH == STRING_EXTEND_WIDTH && N == STRING_N)

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
                                          // This can happen when more than N strings
                                          // are in the beat
    logic                     page_first;
    plain_str_decoder_conf_t  conf;
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

// ------- Stage A: Strings and heap ranges per lane ---------
lane_t     [N - 1:0] lanes_a, lanes_a_next;
beat_info_t          info_a;
logic                valid_a;

always_comb begin
    for (int i = 0; i < N; i++) begin
        pos_t  pos;
        dist_t end_pos;
        logic  length_fits; // Length is below 16, so inline bytes past it are compared

        pos         = in_beat.positions[i];
        end_pos     = dist_t'(pos) + PREFIX_BYTES + in_beat.lengths[i];
        length_fits = in_beat.lengths[i][31:4] == '0;

        lanes_a_next[i].valid   = in_beat.length_keep[i];
        lanes_a_next[i].length  = in_beat.lengths[i];
        lanes_a_next[i].is_long = in_beat.length_keep[i] &&
                                  (!length_fits || in_beat.lengths[i][3:0] > INLINE_BYTES);
        for (int k = 0; k < INLINE_BYTES; k++) begin
            lanes_a_next[i].bytes[k] = !length_fits || k < in_beat.lengths[i][3:0] ?
                                       in_beat.inline_bytes[i][k] : '0;
        end

        lanes_a_next[i].beyond      = lanes_a_next[i].is_long && end_pos > BEAT_WIDTH;
        lanes_a_next[i].heap_start  = off_t'(pos) + PREFIX_BYTES;
        lanes_a_next[i].heap_end    = lanes_a_next[i].beyond ? off_t'(BEAT_WIDTH) : off_t'(end_pos);
        lanes_a_next[i].small_len   = lanes_a_next[i].is_long && !lanes_a_next[i].beyond ?
                                      off_t'(in_beat.lengths[i]) : '0;
        lanes_a_next[i].carry_start = lanes_a_next[i].heap_start > BEAT_WIDTH ?
                                      lanes_a_next[i].heap_start - BEAT_WIDTH : '0;
        lanes_a_next[i].carry_end   = end_pos - BEAT_WIDTH;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_a <= 1'b0;
    end else if (enable) begin
        valid_a <= in.valid && in.ready;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        lanes_a                <= lanes_a_next;
        info_a.data            <= in_beat.data;
        info_a.last            <= in.last;
        info_a.duplicate       <= in_beat.duplicate;
        info_a.page_first      <= page_first;
        info_a.conf            <= conf.data;
    end
end

// ------- Stage B: Heap keep and address offsets of the beat ---------
lane_t      [N - 1:0] lanes_b;
beat_info_t           info_b;
logic                 valid_b;
beat_keep_t           keep_b, keep_b_next;
off_t       [N - 1:0] offsets_b, offsets_b_next; // Long lengths of the lanes before
dist_t                total_b, total_b_next;     // Long lengths of all lanes
logic                 beyond_b, beyond_b_next;
off_t                 carry_start_b, carry_start_b_next;
dist_t                carry_end_b, carry_end_b_next;

always_comb begin
    off_t small_sum;

    keep_b_next        = '0;
    small_sum          = '0;
    total_b_next       = '0;
    beyond_b_next      = 1'b0;
    carry_start_b_next = '0;
    carry_end_b_next   = '0;

    for (int i = 0; i < N; i++) begin
        if (lanes_a[i].is_long) begin
            keep_b_next |= byte_range(lanes_a[i].heap_start, lanes_a[i].heap_end);
        end

        offsets_b_next[i] = small_sum;
        small_sum         = small_sum + lanes_a[i].small_len;

        // Only the last string of a beat can extend past it
        if (lanes_a[i].beyond) begin
            beyond_b_next      = 1'b1;
            total_b_next       = dist_t'(lanes_a[i].length);
            carry_start_b_next = lanes_a[i].carry_start;
            carry_end_b_next   = lanes_a[i].carry_end;
        end
    end

    total_b_next = total_b_next + small_sum;
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_b <= 1'b0;
    end else if (enable) begin
        valid_b <= valid_a;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        lanes_b       <= lanes_a;
        info_b        <= info_a;
        keep_b        <= keep_b_next;
        offsets_b     <= offsets_b_next;
        total_b       <= total_b_next;
        beyond_b      <= beyond_b_next;
        carry_start_b <= carry_start_b_next;
        carry_end_b   <= carry_end_b_next;
    end
end

// ------- Stage C: Heap address and heap keep across beats ---------
addr_t      heap_addr, base_addr;
beat_keep_t gathered_keep; // Heap keep of the duplicates of the current beat
off_t       carry_start;
dist_t      carry_end;
beat_keep_t carry_keep;

assign base_addr  = info_b.page_first && info_b.conf.update_buffer_addr ?
                    addr_t'(info_b.conf.buffer_addr) : heap_addr;
assign carry_keep = byte_range(carry_start, carry_end > BEAT_WIDTH ? off_t'(BEAT_WIDTH) : off_t'(carry_end));

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        heap_addr     <= '0;
        gathered_keep <= '0;
        carry_start   <= '0;
        carry_end     <= '0;
    end else if (enable && valid_b) begin
        heap_addr <= base_addr + total_b;

        if (info_b.duplicate) begin
            gathered_keep <= gathered_keep | keep_b;
        end else begin
            gathered_keep <= '0;

            if (info_b.last) begin
                carry_start <= '0;
                carry_end   <= '0;
            end else if (beyond_b) begin
                carry_start <= carry_start_b;
                carry_end   <= carry_end_b;
            end else begin
                carry_start <= '0;
                carry_end   <= carry_end > BEAT_WIDTH ? carry_end - BEAT_WIDTH : '0;
            end
        end
    end
end

ndata_i #(german_str_t, N)          strings_c(clk, reset_synced);
ndata_i #(data8_t, BEAT_WIDTH)      heap_c(clk, reset_synced);
german_str_t[N - 1:0]               strings_c_next;
logic                               valid_c;
logic                               has_strings_c;
logic                               duplicate_c;

always_comb begin
    for (int i = 0; i < N; i++) begin
        addr_t addr;

        addr = base_addr + offsets_b[i];

        strings_c_next[i].length = lanes_b[i].length;
        for (int k = 0; k < PREFIX_BYTES; k++) begin
            strings_c_next[i].prefix[k] = lanes_b[i].bytes[k];
        end
        for (int k = 0; k < 8; k++) begin
            strings_c_next[i].short_str_or_addr[k] = lanes_b[i].is_long ? addr[k * 8+:8] :
                                                                         lanes_b[i].bytes[PREFIX_BYTES + k];
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        valid_c <= 1'b0;
    end else if (enable) begin
        valid_c <= valid_b;
    end
end

always_ff @(posedge clk) begin
    if (enable) begin
        for (int i = 0; i < N; i++) begin
            strings_c.data[i] <= strings_c_next[i];
            strings_c.keep[i] <= lanes_b[i].valid;
        end
        strings_c.last <= info_b.last;
        has_strings_c  <= lanes_b[0].valid;

        heap_c.data    <= info_b.data;
        heap_c.keep    <= gathered_keep | keep_b | carry_keep;
        heap_c.last    <= info_b.last;
        duplicate_c    <= info_b.duplicate;
    end
end

// ------- Output ---------
// Beats without strings produce no out_strings beat unless they carry last. Duplicates produce no
// out_heap beat.
assign strings_c.valid = valid_c && (has_strings_c || strings_c.last) && heap_c.ready;
assign heap_c.valid    = valid_c && !duplicate_c && strings_c.ready;
assign enable          = !valid_c || (strings_c.ready && heap_c.ready);

NDataSkidBuffer #(german_str_t, N) inst_strings_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(strings_c),
    .out(out_strings)
);

NDataSkidBuffer #(data8_t, BEAT_WIDTH) inst_heap_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(heap_c),
    .out(out_heap)
);

endmodule
