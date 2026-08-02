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

    ready_valid_i.s conf,       // #(type_t)

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


typedef logic [$clog2(INDEX_PATH_COUNT)-1:0] path_idx_t;
function automatic path_idx_t type_to_path (input type_t _type);
    case (_type)
        INT64_T:        type_to_path = path_idx_t'(1);
        DOUBLE_T:       type_to_path = path_idx_t'(1);
        GERMAN_STR_T:   type_to_path = path_idx_t'(2);
        default:        type_to_path = path_idx_t'(0);
    endcase
endfunction

ready_valid_i #(path_idx_t) conf_processed (clk, rst_n);
assign conf_processed.data = type_to_path(conf.data);
assign conf_processed.valid = conf.valid;
assign conf.ready = conf_processed.ready;

ready_valid_i #(path_idx_t) demux_select (clk, rst_n);
ready_valid_i #(path_idx_t) mux_select (clk, rst_n);
RegisteredReadyValidDuplicator #(type_t, 2) inst_conf_duplicate (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (conf_processed),
    .out ({demux_select, mux_select})
);

ready_valid_i #(path_idx_t) _demux_select (clk, rst_n);
`SKID_SIGNAL(path_idx_t, clk, rst_n, demux_select, _demux_select);
ndata_i #(id_t, NUM_ELEMENTS) ins [INDEX_PATH_COUNT] (clk, rst_n);
DataDemultiplexer #(
    INDEX_PATH_COUNT
) inst_demux_input_side (
    .clk    (clk),
    .rst_n  (rst_n),

    .select (_demux_select),

    .in     (in),
    .out    (ins)
);


ready_valid_i #(path_idx_t) _mux_select (clk, rst_n);
`SKID_SIGNAL(path_idx_t, clk, rst_n, mux_select, _mux_select);
ndata_i #(id_t, NUM_ELEMENTS) outs [INDEX_PATH_COUNT] (clk, rst_n);
DataMultiplexer #(
    id_t,
    NUM_ELEMENTS,
    INDEX_PATH_COUNT
) inst_mux_output_side (
    .clk    (clk),
    .rst_n  (rst_n),

    .select (_mux_select),

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
