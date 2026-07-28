`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;

module PlainRouter #(
    parameter int DATABEAT_SIZE,
    parameter int FIXED_PATH_SKID_COUNT = 1
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s page_conf,              // #(page_type_info_t),

    ndata_i.s in_from_stripped,         // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_str_decoder,         // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_to_str_decoder,  // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_values                // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC

// ------ Input skidding ------
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_stripped (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _in_from_str_decoder (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_stripped, _in_from_stripped)
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, in_from_str_decoder, _in_from_str_decoder)


// ------ Plain data input DEMUX  ------
ndata_i #(data8_t, DATABEAT_SIZE) fixed_path (.*);
ndata_i #(data8_t, DATABEAT_SIZE) _fixed_path (.*);

ndata_i #(data8_t, DATABEAT_SIZE) to_str_decoder (.*);
`SKID_NDATA_SIGNAL(data8_t, DATABEAT_SIZE, clk, rst_n, to_str_decoder, out_to_str_decoder)
enum logic {
    VALUE_ROUTER_DEMUX_TO_STR_DEC,
    VALUE_ROUTER_DEMUX_FIXED_PATH
} demux_select_e;
ready_valid_i #(logic) demux_select (.*);
ready_valid_i #(logic) _demux_select (.*);
`SKID_SIGNAL(logic, clk, rst_n, demux_select, _demux_select)

DataDemultiplexer #(2) inst_demux (
    .clk (clk),
    .rst_n (rst_n),

    .select (_demux_select),

    .in (_in_from_stripped),
    .out ({to_str_decoder, fixed_path})
);

// ------ Values Output MUX  ------
enum logic {
    VALUE_ROUTER_MUX_FROM_STR_DEC,
    VALUE_ROUTER_MUX_FROM_FIXED_PATH
} mux_select_e;
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

    .in ({_in_from_str_decoder, _fixed_path}),
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

ready_valid_i #(page_type_info_t) DEMUX_config (.*);
ready_valid_i #(page_type_info_t) DEMUX_config_fw (.*);
RegisteredReadyValidDuplicator #(page_type_info_t, 2) inst_DEMUX1_conf_manager (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (page_conf),
    .out ({DEMUX_config, DEMUX_config_fw})
);
assign demux_select.data =
    DEMUX_config.data.typ == GERMAN_STR_T ?
        VALUE_ROUTER_DEMUX_TO_STR_DEC :
        VALUE_ROUTER_DEMUX_FIXED_PATH;
assign demux_select.valid =
    DEMUX_config.valid &&
    DEMUX_config.data.ptyp == PAGE_TYPE_PLAIN;
assign DEMUX_config.ready = demux_select.ready;

ready_valid_i #(page_type_info_t) MUX_config (.*);

assign MUX_config.data = DEMUX_config_fw.data;
assign MUX_config.valid = DEMUX_config_fw.valid;
assign DEMUX_config_fw.ready = MUX_config.ready;

assign mux_select.data =
    MUX_config.data.typ == GERMAN_STR_T ?
        VALUE_ROUTER_MUX_FROM_STR_DEC :
        VALUE_ROUTER_MUX_FROM_FIXED_PATH;
assign mux_select.valid =
    MUX_config.valid &&
    MUX_config.data.ptyp == PAGE_TYPE_PLAIN;
assign MUX_config.ready = mux_select.ready;


endmodule
