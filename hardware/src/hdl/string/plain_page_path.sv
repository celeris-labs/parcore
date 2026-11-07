`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;
import parcore::*;

/**
 * Routes PLAIN encoded pages through the string decoder or around it, then to out_values (data pages)
 * or out_dictionary (dictionary pages). Each routing decision is consumed with the page's last beat,
 * so a page can enter the string decoder while the previous one still leaves it.
 */
module PlainPagePath #(
    parameter int DATABEAT_SIZE
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,           // #(plain_page_conf_t)

    ndata_i.s in,                   // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_to_str_decoder,   // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_from_str_decoder,  // #(data8_t, DATABEAT_SIZE)

    ndata_i.m out_values,           // #(data8_t, DATABEAT_SIZE)
    ndata_i.m out_dictionary        // #(data8_t, DATABEAT_SIZE)
);

`RESET_RESYNC // Reset pipelining

typedef enum logic {
    PATH_FIXED  = 0,
    PATH_STRING = 1
} path_t;

typedef enum logic {
    DEST_VALUES     = 0,
    DEST_DICTIONARY = 1
} dest_t;

// ------ Config ------------------------------------------------------------------------------------
// The skid buffers let each routing decision be taken at its own page boundary
ready_valid_i #(plain_page_conf_t) confs[3](clk, reset_synced);
ReadyValidDuplicator #(3) inst_conf_duplicator (
    .clk(clk),
    .rst_n(reset_synced),

    .in(conf),
    .out(confs)
);

ready_valid_i #(path_t) _path_in_select(clk, reset_synced);
ready_valid_i #(path_t) _path_out_select(clk, reset_synced);
ready_valid_i #(dest_t) _dest_select(clk, reset_synced);

assign _path_in_select.data  = confs[0].data.is_string ? PATH_STRING : PATH_FIXED;
assign _path_in_select.valid = confs[0].valid;
assign confs[0].ready        = _path_in_select.ready;

assign _path_out_select.data  = confs[1].data.is_string ? PATH_STRING : PATH_FIXED;
assign _path_out_select.valid = confs[1].valid;
assign confs[1].ready         = _path_out_select.ready;

assign _dest_select.data  = confs[2].data.is_dictionary ? DEST_DICTIONARY : DEST_VALUES;
assign _dest_select.valid = confs[2].valid;
assign confs[2].ready     = _dest_select.ready;

ready_valid_i #(path_t) path_in_select(clk, reset_synced);
ready_valid_i #(path_t) path_out_select(clk, reset_synced);
ready_valid_i #(dest_t) dest_select(clk, reset_synced);
SkidBuffer #(path_t) inst_path_in_select_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(_path_in_select), .out(path_in_select));
SkidBuffer #(path_t) inst_path_out_select_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(_path_out_select), .out(path_out_select));
SkidBuffer #(dest_t) inst_dest_select_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(_dest_select), .out(dest_select));

// ------ String decoder or bypass ------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) paths_in[2](clk, reset_synced);
DataDemultiplexer #(2) inst_path_demux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(path_in_select),

    .in(in),
    .out(paths_in)
);

ndata_i #(data8_t, DATABEAT_SIZE) paths_out[2](clk, reset_synced);
NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_bypass_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(paths_in[PATH_FIXED]),
    .out(paths_out[PATH_FIXED])
);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_to_str_decoder_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(paths_in[PATH_STRING]),
    .out(out_to_str_decoder)
);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_from_str_decoder_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_from_str_decoder),
    .out(paths_out[PATH_STRING])
);

ndata_i #(data8_t, DATABEAT_SIZE) page_values(clk, reset_synced);
DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    2
) inst_path_mux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(path_out_select),

    .in(paths_out),
    .out(page_values)
);

// ------ Destination -------------------------------------------------------------------------------
ndata_i #(data8_t, DATABEAT_SIZE) dests[2](clk, reset_synced);
DataDemultiplexer #(2) inst_dest_demux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(dest_select),

    .in(page_values),
    .out(dests)
);

`DATA_ASSIGN(dests[DEST_VALUES], out_values)
`DATA_ASSIGN(dests[DEST_DICTIONARY], out_dictionary)

endmodule
