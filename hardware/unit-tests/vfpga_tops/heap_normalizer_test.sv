`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;
import lynxTypes::*;

/*
 * HeapNormalizer test wiring:
 *   axis_host_recv[0] -> in    (raw heap page bytes)
 *   out               -> axis_host_send[0]  (normalized heap bytes)
 *
 * conf ({generates_heap, last_page}) is driven per page over the config path,
 * mirroring how the parent drives it in the real design.
 */

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

localparam int DATABEAT_SIZE = 64;

/* -- CONFIG ------------------------------------------------------------ */
// HeapNormalizer carries no config registers in the real design (its parent
// drives conf), so the register plumbing lives directly in this test top.
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

ready_valid_i #(logic[1:0]) conf(clk, rst_n);
ConfigWriteFIFO #(0, 8, logic[1:0]) inst_conf (clk, rst_n, write_configs[0], conf);

/* -- INPUT ------------------------------------------------------------- */
AXI4S axi_in (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_in)

ndata_i #(data8_t, DATABEAT_SIZE) in(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in),
    .out(in)
);

/* -- DESIGN WIRING ------------------------------------------------------ */
ndata_i #(data8_t, DATABEAT_SIZE) out(clk, rst_n);
HeapNormalizer #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_heap_normalizer (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),

    .in(in),
    .out(out)
);

/* -- OUTPUT ------------------------------------------------------------ */
AXI4S axi_out (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out),
    .out(axi_out)
);
`AXIS_ASSIGN(axi_out, axis_host_send[0])
