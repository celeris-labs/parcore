`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;
import lynxTypes::*;

/*
 * ValuesRouter (hardware/src/hdl/plain_data.sv) test wiring:
 *
 *   axis_host_recv[0] -> in_from_stripped     (StripLevels output, PLAIN pages)
 *   axis_host_recv[1] -> in_from_dict_body    (DictionaryBody output, DICT pages)
 *   axis_host_recv[2] -> in_from_str_decoder  (PlainStringDecoder output)
 *   axis_host_recv[3] -> in_from_dictionary   (dictionary lookup, HYBRID pages)
 *
 *   out_values              -> axis_host_send[0]
 *   out_to_dict_str_decoder -> axis_host_send[1]
 *   out_to_dict_body        -> axis_host_send[2]
 *
 * page_conf (page_conf_t) is driven per page over the config path, mirroring how
 * the ColumnChunkDecoder page FSM drives it in the real design.
 */

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 3; I < N_STRM_AXI; I++) begin
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
// page_conf), so the register plumbing lives directly in this test top.
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

ready_valid_i #(page_conf_t) page_conf(clk, rst_n);
ConfigWriteFIFO #(0, 8, page_conf_t) inst_page_conf (clk, rst_n, write_configs[0], page_conf);

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

AXI4S axi_in_dict_body (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[1], axi_in_dict_body)

ndata_i #(data8_t, DATABEAT_SIZE) in_from_dict_body(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_dict_body (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_dict_body),
    .out(in_from_dict_body)
);

AXI4S axi_in_str_decoder (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[2], axi_in_str_decoder)

ndata_i #(data8_t, DATABEAT_SIZE) in_from_str_decoder(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_str_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_str_decoder),
    .out(in_from_str_decoder)
);

AXI4S axi_in_dictionary (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[3], axi_in_dictionary)

ndata_i #(data8_t, DATABEAT_SIZE) in_from_dictionary(clk, rst_n);
AXIToNData #(data8_t, DATABEAT_SIZE) inst_axi_to_ndata_dictionary (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_in_dictionary),
    .out(in_from_dictionary)
);

/* -- DESIGN WIRING ------------------------------------------------------ */
ndata_i #(data8_t, DATABEAT_SIZE) out_values(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_to_dict_str_decoder(clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) out_to_dict_body(clk, rst_n);

ValuesRouter #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_values_router (
    .clk(clk),
    .rst_n(rst_n),

    .page_conf(page_conf),

    .in_from_stripped(in_from_stripped),
    .in_from_dict_body(in_from_dict_body),
    .in_from_str_decoder(in_from_str_decoder),
    .in_from_dictionary(in_from_dictionary),

    .out_to_dict_body(out_to_dict_body),
    .out_to_str_decoder(out_to_dict_str_decoder),
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

    .in(out_to_dict_str_decoder),
    .out(axi_out_str_decoder)
);
`AXIS_ASSIGN(axi_out_str_decoder, axis_host_send[1])

AXI4S axi_out_dict_body (.aclk(clk), .aresetn(rst_n));
NDataToAXI #(data8_t, DATABEAT_SIZE) inst_ndata_to_axi_dict_body (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_to_dict_body),
    .out(axi_out_dict_body)
);
`AXIS_ASSIGN(axi_out_dict_body, axis_host_send[2])
