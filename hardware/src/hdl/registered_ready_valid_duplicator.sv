`timescale 1ns / 1ps

/**
 * A registered version of the ReadyValidDuplicator with at least 2 clock cycles of latency.
 * The registered version breaks the ready-valid chain in chained ready-valid modules.
 */
module RegisteredReadyValidDuplicator #(
    parameter type data_t,
    parameter integer NUM_OUTPUTS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in,              // #(data_t)
    ready_valid_i.m out[NUM_OUTPUTS] // #(data_t)
);

ready_valid_i #(data_t) _in (.clk (clk), .rst_n (rst_n));
SkidBuffer #(data_t) inst_skid_buf (
    .clk (clk),
    .rst_n (rst_n),

    .in (in),
    .out (_in)
);

ReadyValidDuplicator #(NUM_OUTPUTS) inst_duplicator (
    .clk (clk),
    .rst_n (rst_n),

    .in (_in),
    .out (out)
);

endmodule
