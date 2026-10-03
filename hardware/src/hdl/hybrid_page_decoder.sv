`timescale 1ns / 1ps

`include "libstf_macros.svh"
`include "lynx_macros.svh"

import lynxTypes::*;
import libstf::data8_t;
import libstf::data32_t;
import parcore::*;

// This module reads the first 4 bytes of the input as an uint32, call it n.
// Then, it computes the offset n+4 and takes in as much input as needed to
// obtain a databeat where the byte at n+4+2 is valid. The byte at n+4+2 is
// parsed as the bit_width. The metadata (bit_width, offest, num_values) is
// then piped to the RunDecoder component, along with the input (including
// current databeat). Num values comes from the conf stream.
//
// The leading length prefix only exists when the page carries definition
// levels: conf.has_def_levels selects an offset of 0 (bit_width is the first
// byte) when there are none. The repetition-level section, if the page has
// one, is stripped by a separate StripLevels instance upstream of this
// module (see column_chunk_decoder.sv), so by the time data reaches here at
// most one section -- the definition-level one -- can remain.
module HybridPageDecoder #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter NUM_BYTES = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    data_i.s conf,           // #(hybrid_page_conf_t) for num_values + has_def_levels

    ndata_i.s in,            // #(data8_t, NUM_BYTES)
    ndata_i.m out            // #(data_t, NUM_ELEMENTS)
);

`RESET_RESYNC // Reset pipelining

localparam int NUM_BYTES_OFFSET = 4;

offset_t    offset;
bit_width_t bit_width;
data32_t    num_values, next_num_values;
logic       page_last;
// Set once the input `last` beat for the current page has been consumed. Used
// to decide whether the page still has trailing (padding) bytes to drain after
// the RunDecoder has produced num_values.
logic       seen_last;

// ------- Run decoder wiring ------
ndata_i #(data8_t, NUM_BYTES)   run_decoder_in(clk, reset_synced);
ndata_i #(data_t, NUM_ELEMENTS) out_inner(clk, reset_synced);
// out_inner with per-page `last` masked when the page is not the last one (conf.last).
ndata_i #(data_t, NUM_ELEMENTS) out_masked(clk, reset_synced);

run_decoder_config_t run_decoder_conf_data;
ready_valid_i #(run_decoder_config_t) run_decoder_conf(clk, reset_synced);
logic run_decoder_conf_valid;

assign run_decoder_conf_data.bit_width = bit_width;
assign run_decoder_conf_data.offset = offset;
assign run_decoder_conf_data.num_values = num_values;
assign run_decoder_conf.data = run_decoder_conf_data;

RunDecoder #(data_t, NUM_ELEMENTS, NUM_BYTES) inst_run_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .in(run_decoder_in),
    .conf(run_decoder_conf),

    .out(out_inner)
);

logic [$clog2(NUM_ELEMENTS):0] out_num_values;
assign out_num_values = $countones(out_inner.keep);

NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_masked),
    .out(out)
);

// ------- State machine ---------
typedef enum logic [2:0] {
    ST_IDLE,
    ST_WAIT,
    ST_CONSUME,
    ST_PIPE,
    ST_DRAIN,
    ST_DUMMY
} state_t;
state_t state;

offset_t bit_width_offset;
// This is used to handle the edge case where the bit width is contained on
// the last byte of a data page and we need to consume it to get to the first
// byte of the data page we can actually pipe to the run decoder.
valid_i #(bit_width_t) keep_bit_width(clk, reset_synced);
assign bit_width = keep_bit_width.valid ? keep_bit_width.data : in.data[bit_width_offset];

// `has_def_levels` of the page currently being set up. process_first_databeat()
// can run in the very cycle the conf beat is accepted (ST_IDLE), when the
// registered copy is not updated yet, so take it straight off the wire there;
// from ST_WAIT onwards the conf beat is gone and the registered copy is the
// only source.
logic page_has_def_levels, cur_has_def_levels;
assign cur_has_def_levels = (state == ST_IDLE) ? conf.data.has_def_levels : page_has_def_levels;

offset_t actual_offset, next_offset;
assign actual_offset = cur_has_def_levels ? (NUM_BYTES_OFFSET + in.data[NUM_BYTES_OFFSET - 1:0]) : '0;
assign next_offset = offset - NUM_BYTES;
assign next_num_values = num_values - out_num_values;

task reset();
    state <= ST_IDLE;
    offset <= '0;
    bit_width_offset <= '0;
    keep_bit_width.valid <= 1'b0;
    run_decoder_conf_valid <= 1'b0;
    seen_last <= 1'b0;
endtask

task process_first_databeat();
    if (actual_offset >= NUM_BYTES - 1) begin
      offset <= actual_offset;
      state <= ST_CONSUME;
    end else begin
      configure(actual_offset + 1, actual_offset);
    end
endtask

task configure(offset_t offst, offset_t bit_width_offst);
    offset <= offst;
    bit_width_offset <= bit_width_offst;
    run_decoder_conf_valid <= 1'b1;
    state <= ST_PIPE;
endtask

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        reset();
    end else begin
        // Remember once the page's `last` input beat has been consumed.
        if (in.valid && in.ready && in.last) begin
            seen_last <= 1'b1;
        end

        case (state)
            ST_IDLE: begin
                if (conf.valid) begin
                    page_last           <= conf.last;
                    page_has_def_levels <= conf.data.has_def_levels;

                    if (!conf.keep) begin
                        // Emit a single empty data beat with the last set high to end the stream.
                        state <= ST_DUMMY;
                    end else begin
                        num_values <= conf.data.num_values;

                        if (in.valid) begin
                            process_first_databeat();
                        end else begin
                            state <= ST_WAIT;
                        end
                    end
                end
            end
            ST_WAIT: begin
                if (in.valid) begin
                    process_first_databeat();
                end
            end
            ST_CONSUME: begin
                if (in.valid) begin
                    if (offset == NUM_BYTES - 1) begin
                        keep_bit_width.data = in.data[NUM_BYTES - 1];
                        keep_bit_width.valid = 1;
                        configure(0, 0);
                    end else begin
                        if (next_offset < NUM_BYTES - 1) begin
                            configure(next_offset + 1, next_offset);
                        end else begin
                            offset <= next_offset;
                        end
                    end
                end
            end
            ST_PIPE: begin
                // If in.valid then the bitwidth field is valid, thus the
                // whole run decoder config, and as such if the handshake
                // happens mark it as invalid to prevent it being consumed
                // multiple times.
                if (in.valid && run_decoder_conf.ready) begin
                    run_decoder_conf_valid <= 1'b0;
                end

                if (out_inner.ready && out_inner.valid) begin
                    num_values <= next_num_values;

                    if (next_num_values == 0) begin
                        // The RunDecoder stops after num_values, but a BPE page
                        // is padded to whole runs (e.g. multiples of 256), so
                        // the final input databeat(s) may carry trailing
                        // padding bytes and the page's `last`. If the page's
                        // `last` beat has already been consumed (earlier) or is
                        // being consumed on this very cycle there is nothing left
                        // to drain and we can reset; otherwise drain the
                        // remaining payload until `last`.
                        if (seen_last || (in.valid && in.last && run_decoder_in.ready)) begin
                            reset();
                        end else begin
                            run_decoder_conf_valid <= 1'b0;
                            state <= ST_DRAIN;
                        end
                    end
                end
            end
            // Swallow the remaining (padding) payload bytes of the finished
            // page until the input `last` beat, then accept the next page.
            ST_DRAIN: begin
                if (in.valid && in.last) begin
                    reset();
                end
            end
            ST_DUMMY: begin
                if (out_masked.ready && out_masked.valid) begin
                    reset();
                end
            end
        endcase
    end
end

// ------- Masking output / dummy injection ---------
// The RunDecoder asserts `last` at the end of every run, but a single page may
// span many runs. We only want a single `last` once the page's num_values are
// exhausted, and only on the last page of the hybrid-page group (page_last).
// The dummy reset beat is a single empty last beat injected directly.
logic page_exhausted;
assign page_exhausted = next_num_values == 0;

always_comb begin
    out_masked.data  = out_inner.data;

    if (state == ST_DUMMY) begin
        out_masked.keep  = '0;
        out_masked.last  = 1'b1;
        out_masked.valid = 1'b1;
        out_inner.ready  = 1'b0;
    end else begin
        out_masked.keep  = out_inner.keep;
        out_masked.last  = page_exhausted && page_last;
        out_masked.valid = out_inner.valid;
        out_inner.ready  = out_masked.ready;
    end
end

// ------- Driving input ---------
assign conf.ready = state == ST_IDLE;
assign in.ready = state == ST_CONSUME || state == ST_DRAIN
              || (state == ST_PIPE && run_decoder_in.ready);

assign run_decoder_in.valid = state == ST_PIPE && in.valid;
assign run_decoder_in.data = in.data;
assign run_decoder_in.keep = in.keep;
assign run_decoder_in.last = in.last;

assign run_decoder_conf.valid = in.valid && run_decoder_conf_valid;

// `ifdef SYNTHESIS
// ila_hybrid_page_decoder inst_hybrid_ila_page_decoder (
//     .clk(clk),
//     .probe0(reset_synced),
//
//     .probe1(state),
//
//     .probe2(in.ready),
//     .probe3(in.valid),
//     .probe4(in.last),
//     .probe5(in.keep),
//
//     .probe6(run_decoder_in.ready),
//     .probe7(run_decoder_in.valid),
//     .probe8(run_decoder_in.last),
//     .probe9(run_decoder_in.keep)
// );
// `endif

endmodule
