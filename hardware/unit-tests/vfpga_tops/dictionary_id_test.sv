`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end

/* -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

localparam int NUM_ELEMENTS = 512 / $bits(data32_t);

/* -- CONFIG ------------------------------------------------------------ */
// IndexGenerator carries no config registers in the real design (its parent
// drives data_type), so the register plumbing lives directly in this test top.
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(PARCORE_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({1})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

always_comb read_configs[0].tie_off_s();

ready_valid_i #(type_t) data_type(clk, rst_n);
ConfigWriteFIFO #(0, 8, type_t) inst_data_type (clk, rst_n, write_configs[0], data_type);

/* -- INPUT ------------------------------------------------------------- */
AXI4S axi_host_recv_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0)

ndata_i #(data32_t, NUM_ELEMENTS) in(clk, rst_n);
AXIToNData #(data32_t, NUM_ELEMENTS) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(in)
);

/* -- DESIGN WIRING ------------------------------------------------------ */
ndata_i #(data32_t, NUM_ELEMENTS) out(clk, rst_n);
DictionaryID #(
    .id_t(data32_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_index_generator (
    .clk(clk),
    .rst_n(rst_n),

    .conf(data_type),
    
    .in(in),
    .out(out)
);

/* -- OUTPUT ------------------------------------------------------------ */
AXI4S axi_host_send_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

NDataToAXI #(data32_t, NUM_ELEMENTS) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out),
    .out(axi_host_send_0)
);
