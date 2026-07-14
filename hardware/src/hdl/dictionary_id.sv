`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;

/**
    Generates dictionary indices according to the incoming data_type
*/
module DictionaryID #(
    parameter type  id_t,
    parameter int   NUM_ELEMENTS,
    parameter int   INDEX_PATH_COUNT = 3 // 32 + 64 + 128
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s dtype,  // Data type for which the dictionary indices should be generated

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

typedef enum logic[1:0] { 
    ENQUEUE_FRONT,
    ENQUEUE_BACK
} state_t;
state_t state;

typedef logic [$clog2(INDEX_PATH_COUNT)-1:0] sel_t;
function automatic sel_t mux_selection (input type_t _type);
    case (_type)
        INT64_T:        mux_selection = sel_t'(1);
        DOUBLE_T:       mux_selection = sel_t'(1);
        GERMAN_STR_T:   mux_selection = sel_t'(2);
        default:        mux_selection = sel_t'(0);
    endcase
endfunction

ready_valid_i #(type_t) _dtype (clk, rst_n);
SkidBuffer #(type_t) inst_dtype_skid (
    .clk (clk),
    .rst_n (rst_n),

    .in (dtype),
    .out (_dtype)
);

ready_valid_i #(select_t) select_front (clk, rst_n);
ready_valid_i #(select_t) _select_front (clk, rst_n);
SkidBuffer #(select_t) inst_select_front_skid (
    .clk (clk),
    .rst_n (rst_n),

    .in (select_front),
    .out (_select_front)
);

ready_valid_i #(select_t) select_back (clk, rst_n);
ready_valid_i #(select_t) _select_back (clk, rst_n);
SkidBuffer #(select_t) inst_select_back_skid (
    .clk (clk),
    .rst_n (rst_n),

    .in (select_back),
    .out (_select_back)
);

select_t current_selection;
assign current_selection = _dtype.data == GERMAN_STR_T ? 1 : 0;

assign select_front.data = mux_selection(_dtype.data);
assign select_front.valid = _dtype.valid && state == ENQUEUE_FRONT;

assign select_back.data = mux_selection(_dtype.data);
assign select_back.valid = _dtype.valid && state == ENQUEUE_BACK;

assign _dtype.ready = state == ENQUEUE_BACK && select_back.ready;

always_ff @( posedge clk ) begin
if (!rst_n) begin
    state <= ENQUEUE_FRONT;
end else begin
    case (state)
        ENQUEUE_FRONT: begin
            if (_dtype.valid && select_front.ready) begin
                state <= ENQUEUE_BACK;
            end
        end 
        ENQUEUE_BACK: begin
            if (_dtype.valid && select_back.ready) begin
                state <= ENQUEUE_FRONT;
            end
        end
        default: begin end
    endcase
end
end

ndata_i #(id_t, NUM_ELEMENTS) ins [INDEX_PATH_COUNT] (clk, rst_n);
ndata_i #(id_t, NUM_ELEMENTS) outs [INDEX_PATH_COUNT] (clk, rst_n);
DataDemultiplexer #(
    INDEX_PATH_COUNT
) inst_demux_input_side (
    .clk    (clk),
    .rst_n  (rst_n),

    .select (_select_front),

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

    .select (_select_back),

    .in     (outs),
    .out    (out)
);

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
