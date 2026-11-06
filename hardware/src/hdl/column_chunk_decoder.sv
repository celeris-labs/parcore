`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import parcore::*;

/**
 * Decodes Parquet column chunks of fixed-width types. Strings need the StringColumnChunkDecoder.
 */
module ColumnChunkDecoder #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // #(column_chunk_conf_t)

    ndata_i.s       in,   // #(data8_t, DATABEAT_SIZE) raw column-chunk bytes
    ndata_i.m       out,  // #(DATABEAT_SIZE)

    decoder_profile_i.m profile
);

ready_valid_i #(page_info_t) page_info (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_pages (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) dests[2] (clk, rst_n);

ColumnChunkDecoderCore #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_core (
    .clk(clk),
    .rst_n(rst_n),

    .conf(conf),

    .in(in),
    .out(out),

    .page_info(page_info),
    .plain_pages(plain_pages),
    .plain_values(dests[0]),
    .dict_values(dests[1]),

    .profile(profile)
);

// ------ PLAIN encoded values ---------------
// Values of data pages go to the output and those of dictionary pages to the Dictionary. Hybrid
// pages carry no PLAIN encoded values, so their page_info is dropped.
ready_valid_i #(logic) dest_select (clk, rst_n);
assign dest_select.data  = page_info.data.page_type == PAGE_TYPE_DICT;
assign dest_select.valid = page_info.valid && page_info.data.page_type != PAGE_TYPE_HYBRID;
assign page_info.ready   = !page_info.valid || page_info.data.page_type == PAGE_TYPE_HYBRID ||
                           dest_select.ready;

DataDemultiplexer #(2) inst_dest_demux (
    .clk(clk),
    .rst_n(rst_n),

    .select(dest_select),

    .in(plain_pages),
    .out(dests)
);

endmodule
