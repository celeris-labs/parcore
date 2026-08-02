`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;
import lynxTypes::*;

/*
 * DictionaryBodyRouter test wiring:
 *   axis_host_recv[0] -> in_body            (raw dictionary body bytes)
 *   axis_host_recv[1] -> in_german_strings  (PSD-decoded strings, german pages only)
 *   out_to_dict       -> axis_host_send[0]  (body forwarded to the dictionary)
 *   out_to_psd        -> axis_host_send[1]  (body forwarded to the PSD, german pages only)
 *
 * conf (type_t) is driven per page over the config path, mirroring how the
 * parent drives it in the real design.
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
// DictionaryBodyRouter carries no config registers in the real design (its
// parent drives conf), so the register plumbing lives directly in this top.
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
AXI4S axi_in_body (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_in_body)

ndata_i #(data8_t, DATABEAT_SIZE) in_body(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_body (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_body),
    .out(in_body)
);

AXI4S axi_in_german (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[1], axi_in_german)

ndata_i #(data8_t, DATABEAT_SIZE) in_german_strings(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_german (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_german),
    .out(in_german_strings)
);

/* -- DESIGN WIRING ------------------------------------------------------ */
ndata_i #(data8_t, DATABEAT_SIZE) out_to_dict(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_to_psd(clk, rst_n);

DictionaryBody #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_dictionary_body_router (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),

    .in_body(in_body),
    .in_german_strings(in_german_strings),

    .out_to_psd(out_to_psd),
    .out_to_dict(out_to_dict)
);

/* -- OUTPUTS ----------------------------------------------------------- */
AXI4S axi_out_dict (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_dict (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_to_dict),
    .out(axi_out_dict)
);
`AXIS_ASSIGN(axi_out_dict, axis_host_send[0])

AXI4S axi_out_psd (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_psd (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_to_psd),
    .out(axi_out_psd)
);
`AXIS_ASSIGN(axi_out_psd, axis_host_send[1])
