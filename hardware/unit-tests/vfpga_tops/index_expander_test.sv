`timescale 1ns / 1ps

`include "lynx_macros.svh"

import libstf::*;


// Expansion factor is configured at compile time via the element widths. The
// python test overrides these with set_system_verilog_defines to exercise
// several factors (defaults give FACTOR = 128/64 = 2).
`ifndef INDEX_EXPANDER_IN_WIDTH
`define INDEX_EXPANDER_IN_WIDTH 128
`endif
`ifndef INDEX_EXPANDER_OUT_WIDTH
`define INDEX_EXPANDER_OUT_WIDTH 64
`endif

initial begin
    $display("INDEX_EXPANDER_IN_WIDTH: ", `INDEX_EXPANDER_IN_WIDTH);
    $display("INDEX_EXPANDER_OUT_WIDTH: ", `INDEX_EXPANDER_OUT_WIDTH);
end

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb axi_ctrl.tie_off_s();   // no runtime config needed
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end

logic clk;
logic rst_n;
assign clk   = aclk;
assign rst_n = aresetn;

localparam int FACTOR = `INDEX_EXPANDER_IN_WIDTH / `INDEX_EXPANDER_OUT_WIDTH;
localparam int NUM_ELEMENTS = 4;
localparam int NUM_ELEMENTS_AXI = 512 / $bits(data32_t);

AXI4S axi_host_recv_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0)

ndata_i #(data32_t, NUM_ELEMENTS_AXI) from_host (clk, rst_n);
AXIToNData #(data32_t, NUM_ELEMENTS_AXI) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(from_host)
);

ndata_i #(data32_t, NUM_ELEMENTS) down_converted (clk, rst_n);
NDataWidthConverter #(
    .data_t(data32_t)
) down_convert_to_NUM_ELEMENTS (
    .clk        (clk),
    .rst_n      (rst_n),

    .in(from_host),
    .out(down_converted)
);

ndata_i #(data32_t, NUM_ELEMENTS * FACTOR) expanded(clk, rst_n);
IndexExpander #(
    .id_t(data32_t),
    .NUM_ELEMENTS_IN(NUM_ELEMENTS),
    .IN_WIDTH(`INDEX_EXPANDER_IN_WIDTH),
    .OUT_WIDTH(`INDEX_EXPANDER_OUT_WIDTH)
) inst_index_expander (
    .clk(clk),
    .rst_n(rst_n),

    .in(down_converted),
    .out(expanded)
);

ndata_i #(data32_t, NUM_ELEMENTS_AXI) expanded_AXI(clk, rst_n);
NDataWidthConverter #(data32_t) acc_for_axi (
    .clk    (aclk),
    .rst_n  (aresetn),

    .in     (expanded),
    .out    (expanded_AXI)
);

AXI4S axi_host_send_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

NDataToAXI #(data32_t, NUM_ELEMENTS_AXI) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(expanded_AXI),
    .out(axi_host_send_0)
);
