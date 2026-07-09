`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;

/**
    Generates dictionary indices according to the incoming data_type
*/
module IndexGenerator #(
    parameter type id_t,
    parameter int   NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s data_type,    // Data type for which the dictionary indices should be generated
    ndata_i.s in,               // #(id_t, NUM_ELEMENTS)
    ndata_i.m out               // #(id_t, NUM_ELEMENTS * FACTOR)
);

// -------- Multiplexing input / Demultiplexing output --------
//
//                demux_in  | (sel_t)       | (sel_t)  mux_out
//                          v               v
//             +--------------------+   +--------------------+
//  in ------->| DataDemultiplexer  |   |  DataMultiplexer   |------> out
//  (id_t x N) |                    |   |                    |  (id_t x N)
//             +--+------+------+---+   +---^------^------^--+
//                |      |      |           |      |      |
//             ins[0] ins[1] ins[2]     outs[0] outs[1] outs[2]
//                |      |      |           |      |      |
//                v      v      v           |      |      |
//             [ Path 0:  32-bit ]----------+      |      |
//             [ Path 1:  64-bit ]-----------------+      |
//             [ Path 2: 128-bit ]------------------------+

localparam INDEX_PATH_COUNT = 3; // 32 + 64 + 128

typedef logic [$clog2(INDEX_PATH_COUNT)-1:0] sel_t;
function automatic sel_t mux_selection (input type_t _type);
    case (_type)
        INT64_T:        mux_selection = sel_t'(1);
        DOUBLE_T:       mux_selection = sel_t'(1);
        GERMAN_STR_T:   mux_selection = sel_t'(2);
        default:        mux_selection = sel_t'(0);
    endcase
endfunction

ready_valid_i #(type_t) _dtype_in (clk, rst_n);
ready_valid_i #(type_t) dtype_in (clk, rst_n);
ready_valid_i #(type_t) _dtype_out (clk, rst_n);
ready_valid_i #(type_t) dtype_out (clk, rst_n);
ready_valid_i #(sel_t) demux_in (clk, rst_n);
ready_valid_i #(sel_t) mux_out (clk, rst_n);

// Use skid buffers as FIFOs to decouple input select with output select
SkidBuffer #(type_t) inst_skid_dtype_in_side (
    .clk(clk),
    .rst_n(rst_n),
    .in(_dtype_in),
    .out(dtype_in)
);

SkidBuffer #(type_t) inst_skid_dtype_out_side (
    .clk(clk),
    .rst_n(rst_n),
    .in(_dtype_out),
    .out(dtype_out)
);

ndata_i #(id_t, NUM_ELEMENTS) ins [INDEX_PATH_COUNT] (clk, rst_n);
ndata_i #(id_t, NUM_ELEMENTS) outs [INDEX_PATH_COUNT] (clk, rst_n);
DataDemultiplexer #(
    INDEX_PATH_COUNT
) inst_demux_input_side (
    .clk    (clk),
    .rst_n  (rst_n),

    .select (demux_in),

    .in     (in),
    .out    (ins)
);
DataMultiplexer #(
    id_t,
    NUM_ELEMENTS,
    INDEX_PATH_COUNT
) inst_mux_output_side (
    .clk    (clk),
    .rst_n  (rst_n),

    .select (mux_out),

    .in     (outs),
    .out    (out)
);

assign demux_in.data = mux_selection(dtype_in.data);
assign demux_in.valid = dtype_in.valid;

assign mux_out.data = mux_selection(dtype_out.data);
assign mux_out.valid = dtype_out.valid;

assign dtype_in.ready = demux_in.ready;
assign dtype_out.ready = mux_out.ready;

assign data_type.ready = _dtype_in.ready && _dtype_out.ready;

assign _dtype_in.valid = data_type.valid && _dtype_out.ready;
assign _dtype_in.data = data_type.data;

assign _dtype_out.valid = data_type.valid && _dtype_in.ready;
assign _dtype_out.data = data_type.data;

// -------- Path 0 (32-bit data): Forwarding  --------
//
// ins[0]                                                outs[0]
//  (id_t x N, 1 index per 32-bit value)                 (id_t x N)
//     |                                                     ^
//     |          +--------------------------+               |
//     +--------->|        SkidBuffer        |---------------+
//                |   inst_32_bit_path_skid  |
//                +--------------------------+

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_32_bit_path_skid (
    .clk(clk),
    .rst_n(rst_n),
    .in(ins[0]),
    .out(outs[0])
);

// -------- Path 1 & 2 (64-bit & 128-bit data): Expansion + Downsizing  --------
//
//  ins[1] (id_t x N)   -- indices for 64 or 128-bit values
//     |
//     v
//  +------------------------------+
//  |          SkidBuffer          |  inst_n_bit_expander_input_skid
//  +------------------------------+
//     |  index_expander_n_bit_in   (id_t x N)
//     v
//  +------------------------------+
//  |     IndexExpander 32 -> n    |
//  |                              |  N indices -> M indices (M = 2 * N or M = 4 * N)
//  +------------------------------+
//     |  index_expander_n_bit_out  (id_t x M)
//     v
//  +------------------------------+
//  |          SkidBuffer          |  inst_n_bit_downsizer_input_skid
//  +------------------------------+
//     |  downsizer_n_bit_in        (id_t x 2N)
//     v
//  +------------------------------+
//  |   NDataWidthConverter        |
//  |         (M -> N)             |
//  +------------------------------+
//     |  downsizer_n_bit_out       (id_t x N)
//     v
//  +------------------------------+
//  |          SkidBuffer          |  inst_n_bit_downsizer_output_skid
//  +------------------------------+
//     |
//     v
//  outs[1] (id_t x N)

// -------- 64-bit data path  --------
ndata_i #(id_t, NUM_ELEMENTS) index_expander_64_bit_in (.*);
ndata_i #(id_t, 2 * NUM_ELEMENTS) index_expander_64_bit_out (.*);
ndata_i #(id_t, 2 * NUM_ELEMENTS) downsizer_64_bit_in (.*);
ndata_i #(id_t, NUM_ELEMENTS) downsizer_64_bit_out (.*);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_64_bit_expander_input_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(ins[1]),
    .out(index_expander_64_bit_in)
);

IndexExpander #(
    .id_t               (id_t),
    .NUM_ELEMENTS_IN    (NUM_ELEMENTS),
    .IN_WIDTH           (64),
    .OUT_WIDTH          (32)
) inst_index_expander_64_bit (
    .clk    (clk),
    .rst_n  (rst_n),

    .in     (index_expander_64_bit_in),
    .out    (index_expander_64_bit_out)
);

NDataSkidBuffer #(id_t, 2 * NUM_ELEMENTS) inst_64_bit_downsizer_input_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(index_expander_64_bit_out),
    .out(downsizer_64_bit_in)
);

NDataWidthConverter #(id_t) inst_downsizer_64_bit (
    .clk(clk),
    .rst_n(rst_n),

    .in(downsizer_64_bit_in),
    .out(downsizer_64_bit_out)
);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_64_bit_downsizer_output_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(downsizer_64_bit_out),
    .out(outs[1])
);

// -------- 128-bit data path  --------
ndata_i #(id_t, NUM_ELEMENTS) index_expander_128_bit_in (.*);
ndata_i #(id_t, 4 * NUM_ELEMENTS) index_expander_128_bit_out (.*);
ndata_i #(id_t, 4 * NUM_ELEMENTS) downsizer_128_bit_in (.*);
ndata_i #(id_t, NUM_ELEMENTS) downsizer_128_bit_out (.*);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_128_bit_expander_input_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(ins[2]),
    .out(index_expander_128_bit_in)
);

IndexExpander #(
    .id_t               (id_t),
    .NUM_ELEMENTS_IN    (NUM_ELEMENTS),
    .IN_WIDTH           (128),
    .OUT_WIDTH          (32)
) inst_index_expander_128_bit (
    .clk    (clk),
    .rst_n  (rst_n),

    .in     (index_expander_128_bit_in),
    .out    (index_expander_128_bit_out)
);

NDataSkidBuffer #(id_t, 4 * NUM_ELEMENTS) inst_128_bit_downsizer_input_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(index_expander_128_bit_out),
    .out(downsizer_128_bit_in)
);

NDataWidthConverter #(id_t) inst_downsizer_128_bit (
    .clk(clk),
    .rst_n(rst_n),

    .in(downsizer_128_bit_in),
    .out(downsizer_128_bit_out)
);

NDataSkidBuffer #(id_t, NUM_ELEMENTS) inst_128_bit_downsizer_output_skid (
    .clk(clk),
    .rst_n(rst_n),

    .in(downsizer_128_bit_out),
    .out(outs[2])
);

endmodule
