`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import parcore_string::*;
import libstf::*;
import lynxTypes::*;

/*
 * PlainPageRouter (hardware/src/hdl/string/plain_page_router.sv) test wiring:
 *
 *   axis_host_recv[0]  -> in                   (PLAIN encoded values of a page)
 *   axis_host_recv[1]  -> in_from_str_decoder  (string decoder output)
 *
 *   out_to_str_decoder -> axis_host_send[0]
 *   out_values         -> axis_host_send[1]
 *   out_dictionary     -> axis_host_send[2]
 *
 * conf (plain_page_conf_t) is written per page over the config path, like the ColumnChunkDecoder
 * page FSM drives it in the real design.
 */

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

always_comb axis_host_recv[2].tie_off_s();
for (genvar I = 3; I < N_STRM_AXI; I++) begin
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

ready_valid_i #(plain_page_conf_t) conf(clk, rst_n);
ConfigWriteFIFO #(0, 8, plain_page_conf_t) inst_conf (clk, rst_n, write_configs[0], conf);

/* -- INPUTS ------------------------------------------------------------ */
AXI4S axi_in (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_in)

ndata_i #(data8_t, DATABEAT_SIZE) in(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_in (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in),
    .out(in)
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
ndata_i #(data8_t, DATABEAT_SIZE) out_to_str_decoder(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_values(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_dictionary(clk, rst_n);

PlainPageRouter #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_plain_page_router (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),

    .in(in),

    .out_to_str_decoder(out_to_str_decoder),
    .in_from_str_decoder(in_from_str_decoder),

    .out_values(out_values),
    .out_dictionary(out_dictionary)
);

/* -- OUTPUTS ----------------------------------------------------------- */
AXI4S axi_out_str_decoder (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_str_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_to_str_decoder),
    .out(axi_out_str_decoder)
);
`AXIS_ASSIGN(axi_out_str_decoder, axis_host_send[0])

AXI4S axi_out_values (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_values (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_values),
    .out(axi_out_values)
);
`AXIS_ASSIGN(axi_out_values, axis_host_send[1])

AXI4S axi_out_dictionary (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_dictionary (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_dictionary),
    .out(axi_out_dictionary)
);
`AXIS_ASSIGN(axi_out_dictionary, axis_host_send[2])
