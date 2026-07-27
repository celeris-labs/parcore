`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;

module StringRouter #(
    parameter int DATABEAT_SIZE
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s page_conf,      // #(page_conf_t),

    ndata_i.s in_from_plain,        // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_dict_body,    // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_str_decoder,   // #(data8_t, DATABEAT_SIZE)
    
    ndata_i.s in_from_str_decoder,  // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_plain,         // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_dict_body      // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC

// ------ Front side MUX ------
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_plain (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_dict_body (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _out_to_str_decoder (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_plain, _in_from_plain)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_dict_body, _in_from_dict_body)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, _out_to_str_decoder, out_to_str_decoder)
enum logic {
    STR_ROUTE_PLAIN_TO_STR_DEC,
    STR_ROUTE_DICT_TO_STR_DEC
} demux_select_e;
ready_valid_i #(logic) mux_select (.*);
ready_valid_i #(logic) _mux_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, mux_select, _mux_select)

DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    2
) inst_mux (
    .clk (clk),
    .rst_n (rst_n),

    .select (_mux_select),

    .in ({_in_from_plain, _in_from_dict_body}),
    .out (_out_to_str_decoder)
);

// ------ Back side DEMUX ------
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_str_decoder (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _out_to_plain (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _out_to_dict_body (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_str_decoder, _in_from_str_decoder)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, _out_to_plain, out_to_plain)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, _out_to_dict_body, out_to_dict_body)
enum logic {
    STR_ROUTE_STR_DEC_TO_PLAIN,
    STR_ROUTE_STR_DEC_TO_DICT_BODY
} demux_select_e;
ready_valid_i #(logic) demux_select (.*);
ready_valid_i #(logic) _demux_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, demux_select, _demux_select)

DataDemultiplexer #(2) inst_demux (
    .clk (clk),
    .rst_n (rst_n),

    .select (_demux_select),

    .in (_in_from_str_decoder),
    .out ({_out_to_plain, _out_to_dict_body})
);

// ------ Config Chain  ------

ready_valid_i #(page_conf_t) MUX_config (.*);
ready_valid_i #(page_conf_t) MUX_config_fw (.*);
RegisteredReadyValidDuplicator #(page_conf_t, 2) inst_MUX1_conf_manager (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (page_conf),
    .out ({MUX_config, MUX_config_fw})
);

assign mux_select.data =
    MUX_config.data.page_type == PAGE_TYPE_PLAIN ?
        STR_ROUTE_PLAIN_TO_STR_DEC :
        STR_ROUTE_DICT_TO_STR_DEC;
assign mux_select.valid =
    MUX_config.valid &&
    MUX_config.data.page_type != PAGE_TYPE_HYBRID &&
    MUX_config.data.typ == GERMAN_STR_T;
assign MUX_config.ready = mux_select.ready;

ready_valid_i #(page_conf_t) DEMUX_config (.*);

assign DEMUX_config.data = MUX_config_fw.data;
assign DEMUX_config.valid = MUX_config_fw.valid;
assign MUX_config_fw.ready = DEMUX_config.ready;
assign demux_select.data =
    MUX_config.data.page_type == PAGE_TYPE_PLAIN ?
        STR_ROUTE_STR_DEC_TO_PLAIN :
        STR_ROUTE_STR_DEC_TO_DICT_BODY;
assign demux_select.valid =
    DEMUX_config.valid &&
    MUX_config.data.page_type != PAGE_TYPE_HYBRID &&
    MUX_config.data.typ == GERMAN_STR_T;
assign DEMUX_config.ready = demux_select.ready;


endmodule
