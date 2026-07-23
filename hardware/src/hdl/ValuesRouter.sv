`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;

module ValuesRouter #(
    parameter int DATABEAT_SIZE,
    parameter int FIXED_PATH_SKID_COUNT = 1
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s page_conf,              // #(page_conf_t),

    ndata_i.s in_from_stripped,         // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_dict_body,        // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_str_decoder,         // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_dictionary,          // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_to_dict_body,         // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_str_decoder,  // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_values                // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC

// ------ Input skidding ------
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_stripped (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_dict_body (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_str_decoder (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_dictionary (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_stripped, _in_from_stripped)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_dict_body, _in_from_dict_body)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_str_decoder, _in_from_str_decoder)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_dictionary, _in_from_dictionary)


// ------ Plain data input DEMUX1  ------
ndata_i #(data8_t, DATABEAT_SIZE) fixed_path (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _fixed_path (.*);

ndata_i #(data8_t, DATABEAT_SIZE) to_str_decoder_mux (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _to_str_decoder_mux (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, to_str_decoder_mux, _to_str_decoder_mux)
enum logic {
    VALUE_ROUTER_DEMUX1_TO_STR_DEC,
    VALUE_ROUTER_DEMUX1_FIXED_PATH
} demux1_select_e;
ready_valid_i #(logic) demux1_select (.*);
ready_valid_i #(logic) _demux1_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, demux1_select, _demux1_select)

DataDemultiplexer #(2) inst_demux_1 (
    .clk (clk),
    .rst_n (rst_n),

    .select (_demux1_select),

    .in (_in_from_stripped),
    .out ({to_str_decoder_mux, fixed_path})
);

// ------ String Decoder Input MUX1  ------
enum logic {
    VALUE_ROUTER_MUX1_FROM_DICT_BODY,
    VALUE_ROUTER_MUX1_FROM_PLAIN
} mux1_select_e;
ready_valid_i #(logic) mux1_select (.*);
ready_valid_i #(logic) _mux1_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, mux1_select, _mux1_select)

DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    2
) inst_mux_1 (
    .clk (clk),
    .rst_n (rst_n),

    .select (_mux1_select),

    .in ({_in_from_dict_body, _to_str_decoder_mux}),
    .out (out_to_str_decoder)
);


// ------ String Decoder Output DEMUX2  ------
ndata_i #(data8_t, DATABEAT_SIZE) from_str_decoder_to_out (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _from_str_decoder_to_out (.*);
enum logic {
    VALUE_ROUTER_DEMUX2_TO_DICT_BODY,
    VALUE_ROUTER_DEMUX2_TO_OUT
} demux2_select_e;
ready_valid_i #(logic) demux2_select (.*);
ready_valid_i #(logic) _demux2_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, demux2_select, _demux2_select)

DataDemultiplexer #(2) inst_demux_2 (
    .clk (clk),
    .rst_n (rst_n),

    .select (_demux2_select),

    .in (_in_from_str_decoder),
    .out ({out_to_dict_body, from_str_decoder_to_out})
);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, from_str_decoder_to_out, _from_str_decoder_to_out)

// ------ Values Output MUX2  ------
enum logic[1:0] {
    VALUE_ROUTER_MUX2_FROM_HYBRID,
    VALUE_ROUTER_MUX2_FROM_STR_DEC,
    VALUE_ROUTER_MUX2_FROM_FIXED_PATH
} mux2_select_e;
ready_valid_i #(logic[1:0]) mux2_select (.*);
ready_valid_i #(logic[1:0]) _mux2_select (.*);
`SKID_SIGNAL(logic[1:0], clk, rst_n, mux2_select, _mux2_select)
DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    3
) inst_mux_2 (
    .clk (clk),
    .rst_n (rst_n),

    .select (_mux2_select),

    .in ({_in_from_dictionary, _from_str_decoder_to_out, _fixed_path}),
    .out (out_values)
);

// ------ Fixed values path skidding  ------

generate
if (FIXED_PATH_SKID_COUNT < 1) begin
    `DATA_ASSIGN(fixed_path, _fixed_path)
end else begin
    ndata_i #(data8_t, DATABEAT_SIZE)
            fixed_path_skid [FIXED_PATH_SKID_COUNT] (clk, reset_synced);
    NDataSkidBuffer #(
        data8_t,
        DATABEAT_SIZE
    ) inst_fixed_path_skid (
        .clk    (clk),
        .rst_n  (reset_synced),

        .in     (fixed_path),
        .out    (fixed_path_skid[0])
    );

    for (genvar i = 1; i < FIXED_PATH_SKID_COUNT; i++) begin
        NDataSkidBuffer #(
            data8_t,
            DATABEAT_SIZE
        ) inst_fixed_path_skid_lvl (
            .clk    (clk),
            .rst_n  (reset_synced),

            .in     (fixed_path_skid[i - 1]),
            .out    (fixed_path_skid[i])
        );
    end
    `DATA_ASSIGN(
        fixed_path_skid[FIXED_PATH_SKID_COUNT - 1],
        _fixed_path
    )
end
endgenerate

// ------ Config Chain  ------

ready_valid_i #(page_conf_t) DEMUX1_config (.*);
ready_valid_i #(page_conf_t) DEMUX1_config_fw (.*);
RegisteredReadyValidDuplicator #(page_conf_t, 2) inst_DEMUX1_conf_manager (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (page_conf),
    .out ({DEMUX1_config, DEMUX1_config_fw})
);
assign demux1_select.data =
    DEMUX1_config.data.typ == GERMAN_STR_T ?
        VALUE_ROUTER_DEMUX1_TO_STR_DEC :
        VALUE_ROUTER_DEMUX1_FIXED_PATH;
assign demux1_select.valid =
    DEMUX1_config.valid &&
    DEMUX1_config.data.page_type == PAGE_TYPE_PLAIN;
assign DEMUX1_config.ready = demux1_select.ready;

ready_valid_i #(page_conf_t) MUX1_config (.*);
ready_valid_i #(page_conf_t) MUX1_config_fw (.*);
RegisteredReadyValidDuplicator #(page_conf_t, 2) inst_MUX1_conf_manager (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (DEMUX1_config_fw),
    .out ({MUX1_config, MUX1_config_fw})
);
assign mux1_select.data =
    MUX1_config.data.page_type == PAGE_TYPE_DICT ?
    VALUE_ROUTER_MUX1_FROM_DICT_BODY :
    VALUE_ROUTER_MUX1_FROM_PLAIN;
assign mux1_select.valid =
    MUX1_config.valid &&
    MUX1_config.data.page_type != PAGE_TYPE_HYBRID &&
    MUX1_config.data.typ == GERMAN_STR_T;
assign MUX1_config.ready = mux1_select.ready;

ready_valid_i #(page_conf_t) DEMUX2_config (.*);
ready_valid_i #(page_conf_t) DEMUX2_config_fw (.*);
RegisteredReadyValidDuplicator #(page_conf_t, 2) inst_DEMUX2_conf_manager (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (MUX1_config_fw),
    .out ({DEMUX2_config, DEMUX2_config_fw})
);
assign demux2_select.data =
    DEMUX2_config.data.page_type == PAGE_TYPE_DICT ?
        VALUE_ROUTER_DEMUX2_TO_DICT_BODY :
        VALUE_ROUTER_DEMUX2_TO_OUT;
assign demux2_select.valid =
    DEMUX2_config.valid &&
    DEMUX2_config.data.page_type != PAGE_TYPE_HYBRID &&
    DEMUX2_config.data.typ == GERMAN_STR_T;
assign DEMUX2_config.ready = demux2_select.ready;

ready_valid_i #(page_conf_t) MUX2_config (.*);

assign MUX2_config.data = DEMUX2_config_fw.data;
assign MUX2_config.valid = DEMUX2_config_fw.valid;
assign DEMUX2_config_fw.ready = MUX2_config.ready;

assign mux2_select.data =
    MUX2_config.data.page_type == PAGE_TYPE_HYBRID ? VALUE_ROUTER_MUX2_FROM_HYBRID :
    MUX2_config.data.typ == GERMAN_STR_T           ? VALUE_ROUTER_MUX2_FROM_STR_DEC : 
                                                     VALUE_ROUTER_MUX2_FROM_FIXED_PATH;
assign mux2_select.valid =
    MUX2_config.valid &&
    MUX2_config.data.page_type != PAGE_TYPE_DICT;
assign MUX2_config.ready = mux2_select.ready;


endmodule
