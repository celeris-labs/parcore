`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::german_str_t;

// Packs the PlainStringDecoder's one-string-per-beat output into full data
// beats. A german string is a fixed 16 bytes, so STRS_PER_BEAT of them tile a
// beat exactly and the only partial beat is the one carrying `last`.
//
// An input beat with keep low contributes no string but still carries the frame
// boundary, so it flushes whatever has been accumulated.
module GermanStrToNData #(
    parameter int DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    data_i.s  in,  // #(german_str_t)
    ndata_i.m out  // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC // Reset pipelining

localparam int STR_BYTES     = $bits(german_str_t) / 8;
localparam int STRS_PER_BEAT = DATABEAT_SIZE / STR_BYTES;
localparam int SLOT_BITS     = (STRS_PER_BEAT > 1) ? $clog2(STRS_PER_BEAT) : 1;

`ASSERT_ELAB(DATABEAT_SIZE % STR_BYTES == 0)

data8_t[DATABEAT_SIZE - 1:0] acc_data,  n_acc_data;
logic  [DATABEAT_SIZE - 1:0] acc_keep,  n_acc_keep;
logic  [SLOT_BITS - 1:0]     slot,      n_slot;

data8_t[DATABEAT_SIZE - 1:0] out_data,  n_out_data;
logic  [DATABEAT_SIZE - 1:0] out_keep,  n_out_keep;
logic                        out_last,  n_out_last;
logic                        out_valid, n_out_valid;

// A new string can be taken whenever the output register is free or draining.
assign in.ready = !out_valid || out.ready;

logic fire;
assign fire = in.valid && in.ready;

logic beat_full;
assign beat_full = in.keep && (slot == SLOT_BITS'(STRS_PER_BEAT - 1));

logic emit;
assign emit = fire && (in.last || beat_full);

always_comb begin
    n_acc_data  = acc_data;
    n_acc_keep  = acc_keep;
    n_slot      = slot;

    n_out_data  = out_data;
    n_out_keep  = out_keep;
    n_out_last  = out_last;
    n_out_valid = out_valid && !out.ready;

    if (fire) begin
        if (in.keep) begin
            n_acc_data[slot * STR_BYTES +: STR_BYTES] = in.data;
            n_acc_keep[slot * STR_BYTES +: STR_BYTES] = '1;
            n_slot                                    = slot + 1'b1;
        end

        if (emit) begin
            n_out_data  = n_acc_data;
            n_out_keep  = n_acc_keep;
            n_out_last  = in.last;
            n_out_valid = 1'b1;

            n_acc_data  = '0;
            n_acc_keep  = '0;
            n_slot      = '0;
        end
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        acc_keep  <= '0;
        slot      <= '0;
        out_valid <= 1'b0;
    end else begin
        acc_data  <= n_acc_data;
        acc_keep  <= n_acc_keep;
        slot      <= n_slot;

        out_data  <= n_out_data;
        out_keep  <= n_out_keep;
        out_last  <= n_out_last;
        out_valid <= n_out_valid;
    end
end

assign out.data  = out_data;
assign out.keep  = out_keep;
assign out.last  = out_last;
assign out.valid = out_valid;

endmodule
