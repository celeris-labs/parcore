`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::*;
import libstf::data8_t;

// Normalized the data in a continguous stream until a number of values have
// been collected. That is specified with the `size` input. This module can be
// configured through `size` only after the previous transfer has finished.
module NormalizeUntil #(
    type data_t,
    type size_t,
    parameter NUM_ELEMENTS = AXI_DATA_BITS / 8,
    parameter ENABLE_COMPACTOR = 0
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s size, // #(size_t)

    ndata_i.s in,         // #(data_t, NUM_ELEMENTS)
    ndata_i.m out         // #(data_t, NUM_ELEMENTS)
);

`RESET_RESYNC // Reset pipelining

size_t remaining;

logic unconfigured;
assign unconfigured = remaining == 0;

assign size.ready = unconfigured;

ndata_i #(data_t, NUM_ELEMENTS) in_inner(clk, reset_synced), normalizer_in(clk, reset_synced), out_inner(clk, reset_synced);

// This is on purpose 1 bit wider to account for the case where keep is 0xf..f
logic [$clog2(NUM_ELEMENTS):0] in_num_values;
assign in_num_values = $countones(in_inner.keep);
size_t next_remaining;
assign next_remaining = remaining - in_num_values;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining <= '0;
    end else begin
        if (unconfigured) begin
            if (size.valid) begin
                remaining <= size.data;
            end
        end else begin
            if (in_inner.ready && in_inner.valid) begin
                remaining <= next_remaining;
            end
        end
    end
end

NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_in_skid_buffer  (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in),
    .out(in_inner)
);

DataNormalizer #(
    .data_t(data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .ENABLE_COMPACTOR(ENABLE_COMPACTOR)
) inst_data_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(normalizer_in),
    .out(out_inner)
);

NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_out_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_inner),
    .out(out)
);

assign in_inner.ready = normalizer_in.ready && ~unconfigured;
assign normalizer_in.valid = in_inner.valid && ~unconfigured;
assign normalizer_in.data = in_inner.data;
assign normalizer_in.keep = in_inner.keep;
assign normalizer_in.last = in_inner.last && next_remaining == 0;

endmodule

module TypedNormalizeUntil #(
    type size_t,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8,
    parameter ENABLE_COMPACTOR = 0,
    parameter BARREL_SHIFTER_REGISTER_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s size, // #(size_t)

    typed_ndata_i.s in,         // #(DATABEAT_SIZE)
    typed_ndata_i.m out         // #(DATABEAT_SIZE)
);

// This should match the maximum latency of this module end-to-end, as in the
// worse case one databeat with last=1 is repeataedly entered in this module,
// each time with a different type. Thus, we need to store an amount of types
// in the FIFO equal to the end-to-end latency.
localparam int MAX_IN_TRANSIT = 8;

`RESET_RESYNC // Reset pipelining

size_t remaining;
ready_valid_i #(type_t) fifo_typ(clk, reset_synced);
valid_i #(type_t) in_typ(clk, reset_synced), out_typ(clk, reset_synced);

logic unconfigured;
assign unconfigured = remaining == 0;

assign size.ready = unconfigured && in.valid;

ndata_i #(data8_t, DATABEAT_SIZE) untyped_in(clk, reset_synced), in_inner(clk, reset_synced), normalizer_in(clk, reset_synced), out_inner(clk, reset_synced), untyped_out(clk, reset_synced);

// This is on purpose 1 bit wider to account for the case where keep is 0xf..f
logic [$clog2(DATABEAT_SIZE):0] in_num_bytes;
assign in_num_bytes = $countones(in_inner.keep);

logic [$clog2(DATABEAT_SIZE):0] in_num_values;

always_comb begin
    in_num_values = '0;

    if (in_typ.valid) begin
        // This is required as simply using:
        //
        // logic [$clog2(DATABEAT_SIZE):0] typ_scale_factor;
        // assign typ_scale_factor = GET_TYPE_WIDTH(out_typ.data) / 8;
        // assign next_remaining = remaining - (in_num_bytes / typ_scale_factor);
        //
        // results in a delayed signal, which is 0 when it shouldn't be, thus
        // resulting in malformed next_remaining data.
        case (in_typ.data)
            BYTE_T: begin
                in_num_values = in_num_bytes;
            end
            INT32_T, FLOAT_T: begin
                in_num_values = in_num_bytes / 4;
            end
            INT64_T, DOUBLE_T: begin
                in_num_values = in_num_bytes / 8;
            end
            INT128_T: begin
                in_num_values = in_num_bytes / 16;
            end
            default: begin
                $fatal(1, "Unexpected type %d in TypedNormalizeUntil", in_typ.data);
            end
        endcase
    end
end

size_t next_remaining;
assign next_remaining = remaining - in_num_values;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining <= '0;
        in_typ.data  <= 'X;
        in_typ.valid <= 1'b0;
        fifo_typ.data  <= 'X;
        fifo_typ.valid <= 1'b0;
    end else begin
        if (unconfigured) begin
            if (in.valid && size.valid) begin
                remaining <= size.data;
                in_typ.data  <= in.typ;
                in_typ.valid <= 1'b1;
                fifo_typ.data  <= in.typ;
                fifo_typ.valid <= 1'b1;
            end
        end else begin
            if (fifo_typ.ready) begin
                fifo_typ.valid <= 1'b0;
            end

            if (normalizer_in.ready && in_inner.valid) begin
                remaining <= next_remaining;

                if (normalizer_in.last) begin
                    in_typ.valid <= 1'b0;
                end
            end
        end
    end
end

MehdiFIFO #(
    .DEPTH(MAX_IN_TRANSIT),
    .WIDTH($bits(type_t))
) inst_type_fifo (
    .i_clk(clk),
    .i_rst_n(reset_synced),

    .i_data(fifo_typ.data),
    .i_valid(fifo_typ.valid),
    .i_ready(fifo_typ.ready),

    .o_data(out_typ.data),
    .o_valid(out_typ.valid),
    .o_ready(out.ready && untyped_out.valid && out.last),

    .o_filling_level()
);

`DATA_ASSIGN(in, untyped_in);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_in_skid_buffer  (
    .clk(clk),
    .rst_n(reset_synced),

    .in(untyped_in),
    .out(in_inner)
);

assign in_inner.ready = normalizer_in.ready && ~unconfigured;
assign normalizer_in.valid = in_inner.valid && ~unconfigured;
assign normalizer_in.data = in_inner.data;
assign normalizer_in.keep = in_inner.keep;
assign normalizer_in.last = in_inner.last && next_remaining == 0;

DataNormalizer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .ENABLE_COMPACTOR(ENABLE_COMPACTOR),
    .BARREL_SHIFTER_REGISTER_LEVELS(BARREL_SHIFTER_REGISTER_LEVELS)
) inst_data_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(normalizer_in),
    .out(out_inner)
);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_out_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_inner),
    .out(untyped_out)
);

assign untyped_out.ready = out.ready && out_typ.valid;
assign out.valid = untyped_out.valid && out_typ.valid;
assign out.data = untyped_out.data;
assign out.keep = untyped_out.keep;
assign out.last = untyped_out.last;
assign out.typ = out_typ.data;

endmodule
