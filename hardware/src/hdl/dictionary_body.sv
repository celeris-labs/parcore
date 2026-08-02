`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;

module DictionaryBody #(
    parameter int DATABEAT_SIZE,
    parameter int DICT_BODY_SKID_CNT = 1,
    parameter int DICT_BODY_PATHS_CNT = 2
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,          // #(type_t),

    ndata_i.s in_body,              // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_german_strings,    // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_to_psd,           // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_dict           // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC

typedef logic[$clog2(DICT_BODY_PATHS_CNT)-1:0] select_t;

ready_valid_i #(select_t) conf_processed (clk, reset_synced);
assign conf_processed.data = conf.data == GERMAN_STR_T ? 1 : 0;
assign conf_processed.valid = conf.valid;
assign conf.ready = conf_processed.ready;

ready_valid_i #(select_t) demux_select (clk, reset_synced);
ready_valid_i #(select_t) _demux_select (clk, reset_synced);
SkidBuffer #(select_t) inst_demux_select_skid (
    .clk (clk),
    .rst_n (reset_synced),

    .in (demux_select),
    .out (_demux_select)
);

ready_valid_i #(select_t) mux_select (clk, reset_synced);
ready_valid_i #(select_t) _mux_select (clk, reset_synced);
SkidBuffer #(select_t) inst_mux_select_skid (
    .clk (clk),
    .rst_n (reset_synced),

    .in (mux_select),
    .out (_mux_select)
);

RegisteredReadyValidDuplicator #(type_t, 2) inst_conf_duplicate (
    .clk (clk),
    .rst_n (rst_n),
    
    .in (conf_processed),
    .out ({demux_select, mux_select})
);

ndata_i #(data8_t, DATABEAT_SIZE)
        dictionary_raw_body [DICT_BODY_PATHS_CNT] (clk, reset_synced);

ndata_i #(data8_t, DATABEAT_SIZE)
        dictionary_processed_body [DICT_BODY_PATHS_CNT] (clk, reset_synced);

DataDemultiplexer #(
    .NUM_STREAMS (DICT_BODY_PATHS_CNT)
) inst_dict_path_demultiplexer (
    .clk (clk),
    .rst_n (reset_synced),

    .select (_demux_select),

    .in (in_body),
    .out (dictionary_raw_body)
);

DataMultiplexer #(
    .data_t (data8_t),
    .NUM_ELEMENTS (DATABEAT_SIZE),
    .NUM_STREAMS (DICT_BODY_PATHS_CNT)
) inst_dict_path_multiplexer (
    .clk (clk),
    .rst_n (reset_synced),

    .select (_mux_select),

    .in (dictionary_processed_body),
    .out (out_to_dict)
);

generate
if (DICT_BODY_SKID_CNT < 1) begin
    `DATA_ASSIGN(dictionary_raw_body[0], dictionary_processed_body[0])
    `DATA_ASSIGN(dictionary_raw_body[1], out_to_psd)
    `DATA_ASSIGN(in_german_strings, dictionary_processed_body[1])
end else begin

    NDataSkidBuffer #(
        data8_t,
        DATABEAT_SIZE
    ) inst_out_to_psd_skid (
        .clk    (clk),
        .rst_n  (reset_synced),

        .in     (dictionary_raw_body[1]),
        .out    (out_to_psd)
    );

    NDataSkidBuffer #(
        data8_t,
        DATABEAT_SIZE
    ) inst_in_german_strings_skid (
        .clk    (clk),
        .rst_n  (reset_synced),

        .in     (in_german_strings),
        .out    (dictionary_processed_body[1])
    );

    ndata_i #(data8_t, DATABEAT_SIZE)
            dictionary_fixed_body [DICT_BODY_SKID_CNT] (clk, reset_synced);
    NDataSkidBuffer #(
        data8_t,
        DATABEAT_SIZE
    ) inst_dictionary_body_no_processing_skid_lvl0 (
        .clk    (clk),
        .rst_n  (reset_synced),

        .in     (dictionary_raw_body[0]),
        .out    (dictionary_fixed_body[0])
    );

    for (genvar i = 1; i < DICT_BODY_SKID_CNT; i++) begin
        NDataSkidBuffer #(
            data8_t,
            DATABEAT_SIZE
        ) inst_dictionary_fixed_body_skid_lvl (
            .clk    (clk),
            .rst_n  (reset_synced),

            .in     (dictionary_fixed_body[i - 1]),
            .out    (dictionary_fixed_body[i])
        );
    end
    `DATA_ASSIGN(
        dictionary_fixed_body[DICT_BODY_SKID_CNT - 1],
        dictionary_processed_body[0]
    )
end
endgenerate


endmodule
