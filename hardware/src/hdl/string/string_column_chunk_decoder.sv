`timescale 1ns / 1ps

`include "libstf_macros.svh"
`include "parcore_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import parcore::*;

/**
 * A ColumnChunkDecoder that also decodes german strings. The strings longer than 12 bytes are
 * written to heap_out, packed across the pages of a column chunk.
 *
 * Every string column chunk takes a heap_addr, the address its heap lands at, which the german
 * strings point into.
 */
module StringColumnChunkDecoder #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,      // #(column_chunk_conf_t)
    ready_valid_i.s heap_addr, // #(vaddress_t)

    ndata_i.s       in,        // #(data8_t, DATABEAT_SIZE) raw column-chunk bytes
    ndata_i.m       out,       // #(DATABEAT_SIZE)
    ndata_i.m       heap_out,  // #(DATABEAT_SIZE)

    decoder_profile_i.m profile
);

`RESET_RESYNC // Reset pipelining

ready_valid_i #(page_info_t) page_info (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_pages (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_values (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) dict_values (clk, rst_n);

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
    .plain_values(plain_values),
    .dict_values(dict_values),

    .profile(profile)
);

// ------ Configuration ---------------
// Every page_info configures the PlainPagePath, the ParallelStringDecoder and the HeapNormalizer.
// Each takes the pages it works on and drops the others.
ready_valid_i #(page_info_t) infos[3] (clk, reset_synced);
RegisteredReadyValidDuplicator #(page_info_t, 3) inst_page_info_duplicator (
    .clk(clk),
    .rst_n(reset_synced),

    .in(page_info),
    .out(infos)
);

function automatic logic plain_encoded(page_info_t info);
    return info.page_type != PAGE_TYPE_HYBRID;
endfunction

function automatic logic is_string(page_info_t info);
    return info.typ == GERMAN_STR_T;
endfunction

// PlainPagePath: all PLAIN encoded pages
ready_valid_i #(plain_page_conf_t) _plain_page_conf (clk, reset_synced);
ready_valid_i #(plain_page_conf_t) plain_page_conf (clk, reset_synced);
assign _plain_page_conf.data = '{
    is_string:     is_string(infos[0].data),
    is_dictionary: infos[0].data.page_type == PAGE_TYPE_DICT
};
assign _plain_page_conf.valid = infos[0].valid && plain_encoded(infos[0].data);
assign infos[0].ready = !infos[0].valid || !plain_encoded(infos[0].data) || _plain_page_conf.ready;
`SKID_SIGNAL(plain_page_conf_t, clk, reset_synced, _plain_page_conf, plain_page_conf)

// ParallelStringDecoder: the PLAIN encoded pages of string column chunks. The first page of a
// column chunk brings its heap address.
logic decoder_page, needs_heap_addr;
assign decoder_page    = infos[1].valid && is_string(infos[1].data) && plain_encoded(infos[1].data);
assign needs_heap_addr = infos[1].data.first_page;

ready_valid_i #(string_decoder_conf_t) _str_decoder_conf (clk, reset_synced);
ready_valid_i #(string_decoder_conf_t) str_decoder_conf (clk, reset_synced);
assign _str_decoder_conf.data = '{
    update_buffer_addr: needs_heap_addr,
    num_values:         infos[1].data.num_values,
    buffer_addr:        needs_heap_addr ? heap_addr.data : '0
};
assign _str_decoder_conf.valid = decoder_page && (!needs_heap_addr || heap_addr.valid);
assign infos[1].ready = !decoder_page || _str_decoder_conf.ready && (!needs_heap_addr || heap_addr.valid);
assign heap_addr.ready = decoder_page && needs_heap_addr && _str_decoder_conf.ready;
`SKID_SIGNAL(string_decoder_conf_t, clk, reset_synced, _str_decoder_conf, str_decoder_conf)

// HeapNormalizer: every page of string column chunks, to end the heap with the column chunk
ready_valid_i #(logic[1:0]) _heap_normalize_conf (clk, reset_synced);
ready_valid_i #(logic[1:0]) heap_normalize_conf (clk, reset_synced);
assign _heap_normalize_conf.data  = {plain_encoded(infos[2].data), infos[2].data.last};
assign _heap_normalize_conf.valid = infos[2].valid && is_string(infos[2].data);
assign infos[2].ready = !infos[2].valid || !is_string(infos[2].data) || _heap_normalize_conf.ready;
`SKID_SIGNAL(logic[1:0], clk, reset_synced, _heap_normalize_conf, heap_normalize_conf)

// ------ PLAIN encoded values ---------------
// Strings go through the string decoder, data pages to the output and dictionary pages to the
// Dictionary
ndata_i #(data8_t, DATABEAT_SIZE) psd_in (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_strings (clk, rst_n);
PlainPagePath #(DATABEAT_SIZE) inst_plain_page_path (
    .clk(clk),
    .rst_n(rst_n),

    .conf(plain_page_conf),

    .in(plain_pages),

    .out_to_str_decoder(psd_in),
    .in_from_str_decoder(psd_strings),

    .out_values(plain_values),
    .out_dictionary(dict_values)
);

// ------ German String Decoder ---------------
ndata_i #(data8_t, DATABEAT_SIZE) psd_heap (clk, rst_n);
ParallelStringDecoder #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_psd (
    .clk(clk),
    .rst_n(rst_n),

    .conf(str_decoder_conf),

    .in_data(psd_in),
    .out_strings(psd_strings),
    .out_heap(psd_heap)
);

// Packs the heap of all pages of a column chunk
HeapNormalizer #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_heap_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(heap_normalize_conf),

    .in(psd_heap),
    .out(heap_out)
);

endmodule
