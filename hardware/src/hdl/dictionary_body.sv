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

    ready_valid_i.s dtype,          // #(type_t),

    ndata_i.s in_body,              // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_german_strings,    // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_to_psd,           // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_to_dict           // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC


typedef enum logic[1:0] { 
    ENQUEUE_FRONT,
    ENQUEUE_BACK
} state_t;
state_t state;

typedef logic[$clog2(DICT_BODY_PATHS_CNT)-1:0] select_t;

ready_valid_i #(type_t) _dtype (clk, reset_synced);
SkidBuffer #(type_t) inst_dtype_skid (
    .clk (clk),
    .rst_n (reset_synced),

    .in (dtype),
    .out (_dtype)
);

ready_valid_i #(select_t) select_front (clk, reset_synced);
ready_valid_i #(select_t) _select_front (clk, reset_synced);
SkidBuffer #(select_t) inst_select_front_skid (
    .clk (clk),
    .rst_n (reset_synced),

    .in (select_front),
    .out (_select_front)
);

ready_valid_i #(select_t) select_back (clk, reset_synced);
ready_valid_i #(select_t) _select_back (clk, reset_synced);
SkidBuffer #(select_t) inst_select_back_skid (
    .clk (clk),
    .rst_n (reset_synced),

    .in (select_back),
    .out (_select_back)
);

select_t current_selection;
assign current_selection = _dtype.data == GERMAN_STR_T ? 1 : 0;

assign select_front.data = current_selection;
assign select_front.valid = _dtype.valid && state == ENQUEUE_FRONT;

assign select_back.data = current_selection;
assign select_back.valid = _dtype.valid && state == ENQUEUE_BACK;

assign _dtype.ready = state == ENQUEUE_BACK && select_back.ready;

always_ff @( posedge clk ) begin
if (!rst_n) begin
    state <= ENQUEUE_FRONT;
end else begin
    case (state)
        ENQUEUE_FRONT: begin
            if (_dtype.valid && select_front.ready) begin
                state <= ENQUEUE_BACK;
            end
        end 
        ENQUEUE_BACK: begin
            if (_dtype.valid && select_back.ready) begin
                state <= ENQUEUE_FRONT;
            end
        end
        default: begin
            
        end
    endcase
end
end

ndata_i #(data8_t, DATABEAT_SIZE)
        dictionary_raw_body [DICT_BODY_PATHS_CNT] (clk, reset_synced);

ndata_i #(data8_t, DATABEAT_SIZE)
        dictionary_processed_body [DICT_BODY_PATHS_CNT] (clk, reset_synced);

DataDemultiplexer #(
    .NUM_STREAMS (DICT_BODY_PATHS_CNT)
) inst_dict_path_demultiplexer (
    .clk (clk),
    .rst_n (reset_synced),

    .select (_select_front),

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

    .select (_select_back),

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
