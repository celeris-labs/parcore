`timescale 1ns / 1ps

`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;
import lynxTypes::*;


/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

always_comb axis_host_recv[1].tie_off_s();
for (genvar I = 2; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end

localparam DATABEAT_SIZE = 64;

write_config_i#(data32_t) conf_config[1] (.clk(aclk), .rst_n(aresetn));
read_config_i#(data64_t) dummy_data[1] (.clk(aclk), .rst_n(aresetn));
logic[AXIL_DATA_BITS - 1:0] dummy_value[2];
assign dummy_value[0] = 64'hDEADBEEFDEADBEEF;
assign dummy_value[1] = 64'hDEADBEEFDEADBEEF;

ready_valid_i#(data32_t)                    latched_num_values  (.clk(aclk), .rst_n(aresetn));
ready_valid_i#(vaddress_t)                  latched_heap_addr   (.clk(aclk), .rst_n(aresetn));
ready_valid_i#(plain_str_decoder_conf_t)    decoder_conf        (.clk(aclk), .rst_n(aresetn));

GlobalConfig#(
    .SYSTEM_ID(0),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({2})
) axi_global_config (
    .clk(aclk),
    .rst_n(aresetn),

    .axi_ctrl(axi_ctrl),
    .write_configs(conf_config),
    .read_configs(dummy_data)
);

ConfigReadRegisterFile#(
    .NUM_REGS(2)
) inst_read_reg_file (
    .clk(aclk),
    .rst_n(aresetn),

    .in(dummy_data[0]),
    .values(dummy_value)
);

ConfigWriteFIFO#(0, 1, data32_t) num_values_config_fifo (
    .clk(aclk),
    .rst_n(aresetn),

    .write_config(conf_config[0]),
    .data(latched_num_values)
);

ConfigWriteFIFO#(1, 1, vaddress_t) heap_addr_config_fifo (
    .clk(aclk),
    .rst_n(aresetn),

    .write_config(conf_config[0]),
    .data(latched_heap_addr)
);

always_comb begin : buildConf
    // A fresh heap base is written alongside every config here, so the decoder
    // reloads it on each page rather than walking on from the previous one.
    decoder_conf.data.update_buffer_addr = 1'b1;
    decoder_conf.data.num_values = latched_num_values.data;
    decoder_conf.data.buffer_addr = latched_heap_addr.data;
    decoder_conf.valid = latched_num_values.valid && latched_heap_addr.valid;
    latched_num_values.ready = decoder_conf.ready && latched_heap_addr.valid;
    latched_heap_addr.ready = decoder_conf.ready && latched_num_values.valid;
end

AXI4S axi_host_recv (.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv)
ndata_i#(data8_t, DATABEAT_SIZE) in (aclk, aresetn);
AXIToNData#(data8_t, DATABEAT_SIZE) inst_axi_to_ndata (
    .clk(aclk),
    .rst_n(aresetn),

    .in(axi_host_recv),
    .out(in)
);

data_i#(german_str_t) strings (aclk, aresetn);
ndata_i#(data8_t, DATABEAT_SIZE) values (aclk, aresetn);
PlainStringDecoder #(DATABEAT_SIZE) plain_str_decoder (
    .clk(aclk),
    .rst_n(aresetn),

    .conf(decoder_conf),
    .in_data(in),
    .out_strings(strings),
    .out_data(values)
);

AXI4S values_to_host (.aclk(aclk), .aresetn(aresetn));
NDataToAXI#(data8_t, DATABEAT_SIZE) val_ndata_to_axi (
    .clk(aclk),
    .rst_n(aresetn),

    .in(values),
    .out(values_to_host)
);
`AXIS_ASSIGN(values_to_host, axis_host_send[0]);

localparam GERMAN_STR_WIDTH = $bits(german_str_t) / 8;
ndata_i#(data8_t, GERMAN_STR_WIDTH) strings_as_bytes (aclk, aresetn);
for (genvar i = 0; i < GERMAN_STR_WIDTH; ++i) begin
    assign strings_as_bytes.data[i] = strings.data[i*8+:8];
    assign strings_as_bytes.keep[i] = strings.keep;
end
assign strings.ready = strings_as_bytes.ready;
assign strings_as_bytes.valid = strings.valid;
assign strings_as_bytes.last = strings.last;

ndata_i#(data8_t, DATABEAT_SIZE) strings_widened (aclk, aresetn);
NDataWidthConverter#(data8_t) strings_widener (
    .clk(aclk),
    .rst_n(aresetn),

    .in(strings_as_bytes),
    .out(strings_widened)
);

AXI4S strings_to_host (.aclk(aclk), .aresetn(aresetn));
NDataToAXI#(data8_t, DATABEAT_SIZE) str_ndata_to_axi (
    .clk(aclk),
    .rst_n(aresetn),

    .in(strings_widened),
    .out(strings_to_host)
);
`AXIS_ASSIGN(strings_to_host, axis_host_send[1]);
