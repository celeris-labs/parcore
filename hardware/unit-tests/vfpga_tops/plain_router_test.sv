`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;
import lynxTypes::*;

/*
 * ValuesRouter (hardware/src/hdl/plain_data.sv) test wiring:
 *
 *   axis_host_recv[0]      -> in_from_stripped     (StripLevels output, PLAIN pages)
 *   axis_host_recv[1]      -> in_from_str_decoder  (PlainStringDecoder output)
 *
 *   out_values             -> axis_host_send[0]
 *   out_to_str_decoder     -> axis_host_send[1]
 *
 * conf (type_t) is driven once per PLAIN page over the config path. The router no
 * longer filters on page type, so DICT and HYBRID pages -- which never reach it --
 * must not be configured, mirroring how the ColumnChunkDecoder drives it.
 */

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 2; I < N_STRM_AXI; I++) begin
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
// ValuesRouter carries no config registers in the real design (its parent drives
// conf), so the register plumbing lives directly in this test top.
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

ready_valid_i #(type_t) conf(clk, rst_n);
ConfigWriteFIFO #(0, 8, type_t) inst_conf (clk, rst_n, write_configs[0], conf);

/* -- INPUTS ------------------------------------------------------------ */
AXI4S axi_in_stripped (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_in_stripped)

ndata_i #(data8_t, DATABEAT_SIZE) in_from_stripped(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_stripped (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_stripped),
    .out(in_from_stripped)
);

AXI4S axi_in_str_decoder (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[1], axi_in_str_decoder)

ndata_i #(data8_t, DATABEAT_SIZE) in_from_str_decoder(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_str_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_str_decoder),
    .out(in_from_str_decoder)
);

/* -- DESIGN WIRING ------------------------------------------------------ */
ndata_i #(data8_t, DATABEAT_SIZE) out_values(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_to_str_decoder(clk, rst_n);

PlainRouter #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_values_router (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),

    .in_from_stripped(in_from_stripped),
    .in_from_str_decoder(in_from_str_decoder),

    .out_to_str_decoder(out_to_str_decoder),
    .out_values(out_values)
);

/* -- OUTPUTS ----------------------------------------------------------- */
AXI4S axi_out_values (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_values (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_values),
    .out(axi_out_values)
);
`AXIS_ASSIGN(axi_out_values, axis_host_send[0])

AXI4S axi_out_str_decoder (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_str_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_to_str_decoder),
    .out(axi_out_str_decoder)
);
`AXIS_ASSIGN(axi_out_str_decoder, axis_host_send[1])
