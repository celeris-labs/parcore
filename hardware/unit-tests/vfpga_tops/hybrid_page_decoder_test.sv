`timescale 1ns / 1ps

`include "lynx_macros.svh"

import parcore::*;
import parcore_test::*;
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

/* -- CONFIG ------------------------------------------------------------ */
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(PARCORE_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({HYBRID_PAGE_DECODER_CONFIG_REGS})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

ready_valid_i #(hybrid_page_conf_t) conf(.*);
HybridPageDecoderConfig inst_hybrid_page_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(conf)
);

/* -- INPUT ------------------------------------------------------------- */

AXI4S axi_host_recv_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0)

ndata_i #(data8_t, 64) in(clk, rst_n);
AXIToNData #(data8_t, 64) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(in)
);

/* -- DESIGN WIRING ----------------------------------------------------- */
// Wrap the per-page (num_values, is_required) config into the data_i conf
// interface. Each configured page is treated as its own hybrid-page group
// (keep=1, last=1), so the decoder emits one last per page.
data_i #(hybrid_page_conf_t) hp_conf(clk, rst_n);
assign hp_conf.data    = conf.data;
assign hp_conf.keep    = 1'b1;
assign hp_conf.last    = 1'b1;
assign hp_conf.valid   = conf.valid;
assign conf.ready = hp_conf.ready;

ndata_i #(data32_t, 16) hybrid_out(clk, rst_n);
HybridPageDecoder #(data32_t, 16) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .conf(hp_conf),

    .in(in),
    .out(hybrid_out)
);

ndata_i #(data32_t, 16) out(clk, rst_n);
DataNormalizer #(
    .data_t(data32_t),
    .NUM_ELEMENTS(16)
) inst_normalizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(hybrid_out),
    .out(out)
);

/* -- OUTPUT ------------------------------------------------------------ */

AXI4S axi_host_send_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

NDataToAXI #(data32_t, 16) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out),
    .out(axi_host_send_0)
);
