`timescale 1ns / 1ps

import libstf::*;

module NDataFIFO # (
    parameter DEPTH, 
    parameter WIDTH,
    parameter STYLE
) (
    input logic clk,
    input logic rst_n,
    
    ndata_i.s in,
    ndata_i.m out

    output logic[$clog2(DEPTH):0] filling_level
);

MehdiFIFO #(
    .DEPTH(DEPTH),
    .WIDTH(WIDTH),
    .STYLE(STYLE)
) inst_ndata_fifo_internal_fifo (
        .i_clk (clk),
        .i_rst_n (rst_n),

        .i_data (in.data),
        .i_valid (in.valid),
        .i_ready (in.ready),

        .o_data (out.data),
        .o_valid (out.valid),
        .o_ready (out.ready),

        .o_filling_level (filling_level)
);

endmodule

module DataInterfaceFIFO # (
    parameter DEPTH, 
    parameter WIDTH,
    parameter STYLE
) (
    input logic clk,
    input logic rst_n,
    
    data_i.s in,
    data_i.m out

    output logic[$clog2(DEPTH):0] filling_level
);

MehdiFIFO #(
    .DEPTH(DEPTH),
    .WIDTH(WIDTH),
    .STYLE(STYLE)
) inst_data_interface_fifo_internal_fifo (
        .i_clk (clk),
        .i_rst_n (rst_n),

        .i_data (in.data),
        .i_valid (in.valid),
        .i_ready (in.ready),

        .o_data (out.data),
        .o_valid (out.valid),
        .o_ready (out.ready),

        .o_filling_level (filling_level)
);

endmodule
