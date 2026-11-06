`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;

/**
    Index expansion that allows mapping the indices of elements of a dtype
    to an indices of elements of a smaller dtype.

    For example, this allows 64-bit element dictionaries to be used for 128-bit elements
    by expanding the indices of 128-bit elements into two indices of tow 64-bit elements:

    INDEX_DTYPE(128b){1, 2} = INDEX_DTYPE(64b){2, 3, 4, 5}
*/
module IndexExpander #(
    parameter type id_t,
    parameter int   NUM_ELEMENTS_IN,
    parameter int   IN_WIDTH,       // input data type width
    parameter int   OUT_WIDTH,      // output data type width
    parameter int   FACTOR = IN_WIDTH / OUT_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,  // #(id_t, NUM_ELEMENTS)
    ndata_i.m out  // #(id_t, NUM_ELEMENTS * FACTOR)
);

// ---------------------------------------------------------------------
// Constraints for the HW module
// 1. Input DTYPE width must be bigger than output DTYPE width
// 2. Input DTYPE width must be a multiple of output DTYPE width
// ---------------------------------------------------------------------
`ASSERT_ELAB(IN_WIDTH >= OUT_WIDTH)
`ASSERT_ELAB(IN_WIDTH % OUT_WIDTH == 0)

localparam int OUT_IDS_COUNT = NUM_ELEMENTS_IN * FACTOR;

for (genvar input_i = 0; input_i < NUM_ELEMENTS_IN; input_i++) begin
    for (genvar out_gen_by_in = 0; out_gen_by_in < FACTOR; out_gen_by_in++) begin
        assign out.data[input_i * FACTOR + out_gen_by_in] = in.data[input_i] * FACTOR + out_gen_by_in;
        assign out.keep[input_i * FACTOR + out_gen_by_in] = in.keep[input_i];
    end
end

assign in.ready = out.ready;
assign out.valid = in.valid;
assign out.last = in.last;

endmodule
