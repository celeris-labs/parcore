`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import libstf::german_str_t;
import libstf::INT32_T;
import libstf::GERMAN_STR_T;
import parcore::*;

module ColumnChunkDecoder #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,   // #(column_chunk_conf_t)

    ndata_i.s       in,     // #(data8_t, DATABEAT_SIZE) raw column-chunk bytes
    ndata_i.m out,          // #(DATABEAT_SIZE)
    ndata_i.m heap_out,     // #(DATABEAT_SIZE)

    decoder_profile_i.m profile
);

`RESET_RESYNC // Reset pipelining

function automatic int unsigned max(int unsigned a, int unsigned b);
    return (a > b) ? a : b;
endfunction

// Number of 32-bit elements per data beat - this is used to size the dictionary
localparam NUM_DICT_ELEM = max(8, DATABEAT_SIZE / ($bits(data32_t) / 8));

// ------ Column Chunk Config wiring -----------------
ready_valid_i #(column_chunk_conf_t) chunk_confs[2](clk, reset_synced);

ReadyValidDuplicator #(2) inst_chunk_conf_duplicator (
    .clk(clk),
    .rst_n(reset_synced),

    .in(conf),
    .out(chunk_confs)
);

// ------ PageHeaderParser -----------------
ready_valid_i #(page_conf_t)         page_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) page_payload(clk, reset_synced);

PageHeaderParser #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_page_header_parser (
    .clk(clk),
    .rst_n(reset_synced),

    .chunk_conf(chunk_confs[1]),

    .in(in),
    .out(page_payload),

    .page_conf(page_conf)
);

// ------ Decompressor ---------------------
ready_valid_i #(compression_t) decompressor_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) decompressor_out(clk, reset_synced);
Decompressor #(DATABEAT_SIZE) inst_decompressor (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(decompressor_conf),

    .in(page_payload),
    .out(decompressor_out)
);


// ------ Page Data Demultiplexing ---------------------
localparam int NUM_IN = 3;
typedef enum logic [$bits(page_type_t) - 1:0] {
    IN_HYBRID = PAGE_TYPE_HYBRID,
    IN_DICT = PAGE_TYPE_DICT,
    IN_PLAIN = PAGE_TYPE_PLAIN
} in_selector_t;
`ASSERT_ELAB(NUM_IN <= 2**$bits(in_selector_t))

ready_valid_i #(in_selector_t) data_page_path_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) ins[NUM_IN](clk, reset_synced);
DataDemultiplexer #(NUM_IN) inst_page_data_demultiplexer (
    .clk(clk),
    .rst_n(reset_synced),

    .select(data_page_path_conf),

    .in(decompressor_out),
    .out(ins)
);

// ------ Plain Data Path ---------------

ndata_i #(data8_t, DATABEAT_SIZE) plain_in(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) plain_stripped(clk, reset_synced);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_plain_in_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(ins[IN_PLAIN]),
    .out(plain_in)
);

StripLevels #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_strip_levels (
    .clk(clk),
    .rst_n(reset_synced),

    .in(plain_in),
    .out(plain_stripped)
);

ready_valid_i #(type_t) plain_router_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) stripped_to_plain (clk, rst_n);
`DATA_ASSIGN(plain_stripped, stripped_to_plain)
ndata_i #(data8_t, DATABEAT_SIZE) str_decoder_to_plain (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_to_str_decoder (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_to_out (clk, rst_n);
PlainRouter #(DATABEAT_SIZE) inst_values_router (
    .clk (clk),
    .rst_n (rst_n),

    .conf (plain_router_conf),

    .in_from_stripped (stripped_to_plain),
    .in_from_str_decoder (str_decoder_to_plain),

    .out_to_str_decoder (plain_to_str_decoder),
    .out_values (plain_to_out)
);

// ------ German String Decoder ---------------

ready_valid_i #(plain_str_decoder_conf_t) plain_str_decoder_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_in (clk, rst_n);
data_i #(german_str_t) psd_out_strings (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_strings_packed (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_out_heap (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) dict_body_to_str_decoder (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) str_decoder_to_dict_body (clk, rst_n);
PlainStringDecoder #(DATABEAT_SIZE) inst_psd (
    .clk (clk),
    .rst_n (rst_n),

    .conf (plain_str_decoder_conf),

    .in_data (psd_in),
    .out_strings (psd_out_strings),
    .out_data (psd_out_heap)
);

// The heap normalizer is used to pack the heap values across pages
ready_valid_i #(logic[1:0]) heap_normalize_conf (clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) heap_packed (clk, reset_synced);

HeapNormalizer #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_heap_normalizer (
    .clk (clk),
    .rst_n (reset_synced),

    .conf (heap_normalize_conf),

    .in (psd_out_heap),
    .out (heap_packed)
);

`DATA_ASSIGN(heap_packed, heap_out)

GermanStrToNData #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_psd_string_packer (
    .clk (clk),
    .rst_n (reset_synced),

    .in (psd_out_strings),
    .out (psd_strings_packed)
);

ready_valid_i #(page_type_info_t) str_router_conf (clk, rst_n);
StringRouter #(DATABEAT_SIZE) inst_str_router (
    .clk (clk),
    .rst_n (rst_n),

    .conf (str_router_conf),

    .in_from_plain (plain_to_str_decoder),
    .in_from_dict_body (dict_body_to_str_decoder),
    .out_to_str_decoder (psd_in),

    .in_from_str_decoder (psd_strings_packed),
    .out_to_plain (str_decoder_to_plain),
    .out_to_dict_body (str_decoder_to_dict_body)
);

// ------ Dictionary Page Path ---------------
ndata_i #(data8_t, DATABEAT_SIZE) dict_body_to_dict (clk, rst_n);
ready_valid_i #(type_t) dict_body_conf (clk, reset_synced);
DictionaryBody #(DATABEAT_SIZE) inst_dict_body (
    .clk (clk),
    .rst_n (reset_synced),

    .conf (dict_body_conf),

    .in_body (ins[IN_DICT]),
    .in_german_strings (str_decoder_to_dict_body),

    .out_to_psd (dict_body_to_str_decoder),
    .out_to_dict (dict_body_to_dict)
);


// ------ Dictionary Encoded Path ---------------
data_i #(data32_t) hybrid_page_decoder_conf(clk, reset_synced);
ndata_i #(id_t, NUM_DICT_ELEM) dict_ids_native (clk, reset_synced);
HybridPageDecoder #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM),
    .NUM_BYTES(DATABEAT_SIZE)
) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(hybrid_page_decoder_conf),

    .in(ins[IN_HYBRID]),
    .out(dict_ids_native)
);

ready_valid_i #(type_t) dict_id_conf (clk, rst_n);
ndata_i #(id_t, NUM_DICT_ELEM) dict_ids_scaled (clk, reset_synced);
DictionaryID #(
    id_t,
    NUM_DICT_ELEM
) inst_index_conversion (
    .clk(clk),
    .rst_n(reset_synced),

    .conf (dict_id_conf),

    .in (dict_ids_native),
    .out (dict_ids_scaled)
);

// The Dictionary indexes 32-bit values while the rest of the path moves bytes.
// These wires logically convert one to another
ndata_i #(data32_t, NUM_DICT_ELEM) dict_in_values  (clk, reset_synced);
ndata_i #(data32_t, NUM_DICT_ELEM) dict_out_values (clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) dict_decoded_bytes (.*);

assign dict_in_values.data     = dict_body_to_dict.data;
assign dict_in_values.last     = dict_body_to_dict.last;
assign dict_in_values.valid    = dict_body_to_dict.valid;
assign dict_body_to_dict.ready = dict_in_values.ready;

assign dict_decoded_bytes.data  = dict_out_values.data;
assign dict_decoded_bytes.last  = dict_out_values.last;
assign dict_decoded_bytes.valid = dict_out_values.valid;
assign dict_out_values.ready    = dict_decoded_bytes.ready;

for (genvar I = 0; I < NUM_DICT_ELEM; I++) begin
    assign dict_in_values.keep[I] = &dict_body_to_dict.keep[4*I +: 4];
    assign dict_decoded_bytes.keep[4*I +: 4] = {4{dict_out_values.keep[I]}};
end

Dictionary #(
    .value_t(data32_t),
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM)
) inst_dictionary (
    .clk(clk),
    .rst_n(reset_synced),

    .in_values(dict_in_values),
    .in_ids(dict_ids_scaled),

    .out(dict_out_values)
);

ready_valid_i #(data32_t) rewrite_last_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) hybrid_path_out (.*);
DataRewriteLast #(
    .data_t(data8_t),
    .NUM_ELEMENTS (DATABEAT_SIZE)
) inst_reinsert_last_for_hybrid_path (
    .clk (clk),
    .rst_n (rst_n),

    .num_elements (rewrite_last_conf),

    .in (dict_decoded_bytes),
    .out (hybrid_path_out)
);

// ------ Output Multiplexing ---------------
localparam int NUM_OUT = 2;
typedef enum logic {
  OUT_PLAIN  = 0,
  OUT_HYBRID = 1
} out_selector_t;
`ASSERT_ELAB(NUM_OUT <= 2**$bits(out_selector_t))
ndata_i #(data8_t, DATABEAT_SIZE) outs[NUM_OUT](clk, reset_synced);

`DATA_ASSIGN(plain_to_out, outs[OUT_PLAIN])
`DATA_ASSIGN(hybrid_path_out, outs[OUT_HYBRID])

ready_valid_i #(logic) out_mux_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) per_page_out(clk, reset_synced);
DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    NUM_OUT
) inst_out_mux (
    .clk (clk),
    .rst_n (rst_n),

    .select (out_mux_conf),

    .in (outs),
    .out(per_page_out)
);

ready_valid_i #(data32_t) normalize_until_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) per_cc_out (clk, reset_synced);
NormalizeUntil #(
    data8_t,
    data32_t,
    DATABEAT_SIZE
) inst_page_value_collector (
    .clk (clk),
    .rst_n (rst_n),

    .size (normalize_until_conf),

    .in (per_page_out),
    .out (per_cc_out)
);

`DATA_ASSIGN(per_cc_out, out)

// ------------------------------------------------------------------
// ------ Config distribution ---------------------------------------
// ------------------------------------------------------------------


typedef enum logic[1:0] {
    WAIT_FOR_CC_CONF,
    WAIT_FOR_PAGE_CONF,
    CONFIGURE,
    WAIT_CONSUMPTION
} state_t;
state_t state;

logic first_page;
logic dict_page_seen;
logic hybrid_page_seen;

column_chunk_conf_t cc_conf_latched;
page_conf_t page_conf_r;

logic all_modules_consumed_configs;

always_ff @( posedge clk )
if (!reset_synced) begin
    state <= WAIT_FOR_CC_CONF;
    first_page <= 1;
    dict_page_seen <= 0;
    hybrid_page_seen <= 0;
end else begin
    case (state)
        WAIT_FOR_CC_CONF:
            if (chunk_confs[0].valid) begin
                cc_conf_latched <= chunk_confs[0].data;
                state           <= WAIT_FOR_PAGE_CONF;
            end
        WAIT_FOR_PAGE_CONF:
            if (page_conf.valid) begin
                page_conf_r   <= page_conf.data; 
                state               <= CONFIGURE;
            end
        CONFIGURE:
            state <= WAIT_CONSUMPTION;
        WAIT_CONSUMPTION: begin
            if (all_modules_consumed_configs) begin
                if (page_conf_r.last) begin
                    state <= WAIT_FOR_CC_CONF;
                    first_page <= 1;
                    dict_page_seen <= 0;
                    hybrid_page_seen <= 0;
                end else begin
                    state <= WAIT_FOR_PAGE_CONF;
                    first_page <= 0;
                    dict_page_seen <=
                            dict_page_seen || page_conf_r.page_type == PAGE_TYPE_DICT;
                    hybrid_page_seen <= 
                            hybrid_page_seen || page_conf_r.page_type == PAGE_TYPE_HYBRID;
                end
            end
        end
    endcase
end


function automatic logic n_conf_valid(input logic conf_valid, conf_ready, configure_when);
    case (state)
        CONFIGURE:        n_conf_valid = configure_when;
        WAIT_CONSUMPTION: n_conf_valid = conf_valid && !conf_ready;
        default:          n_conf_valid = 1'b0;
    endcase
endfunction

localparam logic FOR_EVERY_PAGE = 1;

// ------ Frontend configuration ---------------------------------------
ready_valid_i #(compression_t) _decompressor_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_decompressor
    _decompressor_conf.valid <= n_conf_valid(
        _decompressor_conf.valid,
        _decompressor_conf.ready,
        FOR_EVERY_PAGE
    );
    _decompressor_conf.data <= cc_conf_latched.compression;
end
`SKID_SIGNAL(compression_t, clk, rst_n, _decompressor_conf, decompressor_conf)

ready_valid_i #(in_selector_t) _data_page_path_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_data_page_path
    _data_page_path_conf.valid <= n_conf_valid(
        _data_page_path_conf.valid,
        _data_page_path_conf.ready,
        FOR_EVERY_PAGE
    );
    _data_page_path_conf.data <= in_selector_t'(page_conf_r.page_type);
end
`SKID_SIGNAL(in_selector_t, clk, rst_n, _data_page_path_conf, data_page_path_conf)


// ------ Hybrid Path configuration ---------------------------------------
/**
 *
 * The hybrid path has a special edge case that needs to be handled with a
 * dummy beat (PLAIN fallback):
 *
 * If a column chunk starts with dictionary encoding but ends on PLAIN
 * encoded data pages, the routing elements of the hybrid path and the
 * dictionary itself will never see a last signal, as the HybridPageDecoder
 * only emits a last signal iff it receives the last page of the column
 * chunk. In the case of PLAIN fallback, the HybridPageDecoder never
 * receives the last page, thus the routing elements and dictionary are
 * never reset and thus misconfigured for the next column chuk.
 */

data_i #(data32_t) _hybrid_page_decoder_conf (clk, reset_synced);
// This condition is only true if a PLAIN fallback occured
logic hybrid_flush;
assign hybrid_flush = page_conf_r.last &&
            page_conf_r.page_type == PAGE_TYPE_PLAIN &&
            dict_page_seen;

logic enqueue_hybrid_page_decoder_conf;
assign enqueue_hybrid_page_decoder_conf = hybrid_flush ||
                     page_conf_r.page_type == PAGE_TYPE_HYBRID;
always_ff @( posedge clk ) begin : configure_hybrid_page_decoder
    _hybrid_page_decoder_conf.valid <= n_conf_valid(
        _hybrid_page_decoder_conf.valid,
        _hybrid_page_decoder_conf.ready,
        enqueue_hybrid_page_decoder_conf
    );

    // All these signals remain stable during configuration
    _hybrid_page_decoder_conf.data <= hybrid_flush ? '0 : page_conf_r.num_values;
    _hybrid_page_decoder_conf.keep <= ~hybrid_flush;
    _hybrid_page_decoder_conf.last <= page_conf_r.last;
end
`SKID_DATA_SIGNAL(data32_t, clk, rst_n, _hybrid_page_decoder_conf, hybrid_page_decoder_conf)

// The Hybrid path routing needs to be once per hybrid pages group
ready_valid_i #(type_t) _dict_id_conf (clk, rst_n);
logic enqueue_dict_id_conf;
assign enqueue_dict_id_conf =
        !hybrid_page_seen &&
        (hybrid_flush || page_conf_r.page_type == PAGE_TYPE_HYBRID);
always_ff @( posedge clk ) begin : configure_dict_id
    _dict_id_conf.valid <= n_conf_valid(
        _dict_id_conf.valid,
        _dict_id_conf.ready,
        enqueue_dict_id_conf
    );
    _dict_id_conf.data <= hybrid_flush ? INT32_T : cc_conf_latched.typ;
end
`SKID_SIGNAL(type_t, clk, rst_n, _dict_id_conf, dict_id_conf)

ready_valid_i #(data32_t) _rewrite_last_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_rewrite_last
    _rewrite_last_conf.valid <= n_conf_valid(
        _rewrite_last_conf.valid,
        _rewrite_last_conf.ready,
        page_conf_r.page_type == PAGE_TYPE_HYBRID
    );
    _rewrite_last_conf.data <=
        page_conf_r.num_values * GET_TYPE_BYTES(cc_conf_latched.typ);
end
`SKID_SIGNAL(data32_t, clk, rst_n, _rewrite_last_conf, rewrite_last_conf)

// ------ Dictionary Page Path configuration ---------------------------------------
ready_valid_i #(type_t) _dict_body_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_dict_body
    _dict_body_conf.valid <= n_conf_valid(
        _dict_body_conf.valid,
        _dict_body_conf.ready,
        page_conf_r.page_type == PAGE_TYPE_DICT
    );
    _dict_body_conf.data <= cc_conf_latched.typ;
end
`SKID_SIGNAL(type_t, clk, rst_n, _dict_body_conf, dict_body_conf)

// ------ Plain Data Page Path configuration ---------------------------------------
ready_valid_i #(type_t) _plain_router_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_plain_router
    _plain_router_conf.valid <= n_conf_valid(
        _plain_router_conf.valid,
        _plain_router_conf.ready,
        page_conf_r.page_type == PAGE_TYPE_PLAIN
    );
    _plain_router_conf.data <= cc_conf_latched.typ;
end
`SKID_SIGNAL(type_t, clk, rst_n, _plain_router_conf, plain_router_conf)

// ------ String Path configuration ---------------------------------------
ready_valid_i #(page_type_info_t) _str_router_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_str_router
    _str_router_conf.valid <= n_conf_valid(
        _str_router_conf.valid,
        _str_router_conf.ready,
        FOR_EVERY_PAGE
    );
    _str_router_conf.data <= {
        cc_conf_latched.typ,
        page_conf_r.page_type,
        page_conf_r.last
    };
end
`SKID_SIGNAL(page_type_info_t, clk, rst_n, _str_router_conf, str_router_conf)

ready_valid_i #(plain_str_decoder_conf_t) _plain_str_decoder_conf (clk, rst_n);
logic plain_str_decoder_active;
assign plain_str_decoder_active =
    cc_conf_latched.typ == GERMAN_STR_T &&
    page_conf_r.page_type != PAGE_TYPE_HYBRID;

always_ff @( posedge clk ) begin : configure_plain_str_decoder
    _plain_str_decoder_conf.valid <= n_conf_valid(
        _plain_str_decoder_conf.valid,
        _plain_str_decoder_conf.ready,
        plain_str_decoder_active
    );
    _plain_str_decoder_conf.data <= {
        first_page,
        page_conf_r.num_values,
        cc_conf_latched.string_heap_addr
    };
end
`SKID_SIGNAL(plain_str_decoder_conf_t, clk, rst_n, _plain_str_decoder_conf, plain_str_decoder_conf)

ready_valid_i #(logic[1:0]) _heap_normalize_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_heap_normalize
    _heap_normalize_conf.valid <= n_conf_valid(
        _heap_normalize_conf.valid,
        _heap_normalize_conf.ready,
        cc_conf_latched.typ == GERMAN_STR_T
    );
    _heap_normalize_conf.data <= {
        page_conf_r.page_type != PAGE_TYPE_HYBRID,
        page_conf_r.last
    };
end
`SKID_SIGNAL(logic[1:0], clk, rst_n, _heap_normalize_conf, heap_normalize_conf)

// ------ Output MUX control ---------------------------------------
ready_valid_i #(logic) _out_mux_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_out_mux
    _out_mux_conf.valid <= n_conf_valid(
        _out_mux_conf.valid,
        _out_mux_conf.ready,
        page_conf_r.page_type != PAGE_TYPE_DICT
    );
    _out_mux_conf.data <= page_conf_r.page_type == PAGE_TYPE_HYBRID ?
            OUT_HYBRID :
            OUT_PLAIN;
end
`SKID_SIGNAL(logic, clk, rst_n, _out_mux_conf, out_mux_conf)

// ------ Column Chunk level configurations ---------------------------------------
ready_valid_i #(data32_t) _normalize_until_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_normalize_until
    _normalize_until_conf.valid <= n_conf_valid(
        _normalize_until_conf.valid,
        _normalize_until_conf.ready,
        first_page
    );
    _normalize_until_conf.data <= 
        cc_conf_latched.num_values * GET_TYPE_BYTES(cc_conf_latched.typ);
end
`SKID_SIGNAL(data32_t, clk, rst_n, _normalize_until_conf, normalize_until_conf)

assign all_modules_consumed_configs =
        !_decompressor_conf.valid &&
        !_data_page_path_conf.valid &&
        !_hybrid_page_decoder_conf.valid &&
        !_dict_id_conf.valid &&
        !_dict_body_conf.valid &&
        !_plain_router_conf.valid &&
        !_str_router_conf.valid &&
        !_plain_str_decoder_conf.valid &&
        !_rewrite_last_conf.valid &&
        !_out_mux_conf.valid &&
        !_normalize_until_conf.valid;
assign chunk_confs[0].ready = state == WAIT_FOR_CC_CONF;
assign page_conf.ready = state == WAIT_FOR_PAGE_CONF;

// ------ Stream profiling ------------------------
stream_profile_i profile_in ();
stream_profile_i profile_out();

assign profile.counters.in  = profile_in.counters;
assign profile.counters.out = profile_out.counters;
assign profile_in.stop      = profile.stop;
assign profile_out.stop     = profile.stop;

StreamProfiler inst_profile_in (
    .clk(clk),
    .rst_n(reset_synced),

    .last (in.last),
    .valid(in.valid),
    .ready(in.ready),

    .profile(profile_in)
);

StreamProfiler inst_profile_out (
    .clk(clk),
    .rst_n(reset_synced),

    .last (out.last),
    .valid(out.valid),
    .ready(out.ready),

    .profile(profile_out)
);

// ------ Heap path instrumentation ---------------------------------------
// Counts what the decoder puts on psd_out_heap, the PlainStringDecoder's heap
// output as it enters HeapNormalizer. This is the last point before the packing
// and last-rewriting, so comparing these against what the host receives says
// whether a missing heap completion was never produced or was lost downstream.
//
// Free running and 32 bits, so the byte count wraps after 4 GiB. Only the deltas
// across a chunk are meaningful; lasts is the interesting one, since it should
// equal the number of string chunks decoded.
data32_t heap_in_beats, heap_in_lasts, heap_in_bytes;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        heap_in_beats <= '0;
        heap_in_lasts <= '0;
        heap_in_bytes <= '0;
    end else if (psd_out_heap.valid && psd_out_heap.ready) begin
        heap_in_beats <= heap_in_beats + 1;
        heap_in_lasts <= heap_in_lasts + data32_t'(psd_out_heap.last);
        heap_in_bytes <= heap_in_bytes + data32_t'($countones(psd_out_heap.keep));
    end
end

`ifdef DEBUG
// Every port of the five modules that can stall the pipeline on their own:
// Decompressor, HybridPageDecoder, Dictionary, PlainStringDecoder and the
// output multiplexer. A blocked stream reads as valid=1 with ready=0, so
// ready is captured alongside valid - without it the trace says something is
// stuck but not which side is holding it up.
//
// None of these widths depend on DATABEAT_SIZE, so one IP serves both the 32-
// and 64-byte configurations.
ila_cc_decoder inst_ila_cc_decoder (
    .clk(clk),
    .probe0(reset_synced),
    .probe1(state),

    // Decompressor
    .probe2(decompressor_conf.valid),
    .probe3(decompressor_conf.ready),
    .probe4(page_payload.valid),
    .probe5(page_payload.ready),
    .probe6(decompressor_out.valid),
    .probe7(decompressor_out.ready),

    // HybridPageDecoder
    .probe8(hybrid_page_decoder_conf.valid),
    .probe9(hybrid_page_decoder_conf.ready),
    .probe10(ins[IN_HYBRID].valid),
    .probe11(ins[IN_HYBRID].ready),
    .probe12(dict_ids_native.valid),
    .probe13(dict_ids_native.ready),

    // Dictionary
    .probe14(dict_in_values.valid),
    .probe15(dict_in_values.ready),
    .probe16(dict_ids_scaled.valid),
    .probe17(dict_ids_scaled.ready),
    .probe18(dict_out_values.valid),
    .probe19(dict_out_values.ready),

    // PlainStringDecoder
    .probe20(plain_str_decoder_conf.valid),
    .probe21(plain_str_decoder_conf.ready),
    .probe22(psd_in.valid),
    .probe23(psd_in.ready),
    .probe24(psd_out_strings.valid),
    .probe25(psd_out_strings.ready),
    .probe26(psd_out_heap.valid),
    .probe27(psd_out_heap.ready),

    // Output multiplexer
    .probe28(out_mux_conf.valid),
    .probe29(out_mux_conf.ready),
    .probe30(plain_to_out.valid),
    .probe31(plain_to_out.ready),
    .probe32(hybrid_path_out.valid),
    .probe33(hybrid_path_out.ready),
    .probe34(per_page_out.valid),
    .probe35(per_page_out.ready),

    // Heap-path counters: a chunk that ends with heap_in_lasts incremented but
    // nothing arriving at the host means the last was swallowed downstream.
    .probe36(heap_in_beats),
    .probe37(heap_in_lasts),
    .probe38(heap_in_bytes)
);
`endif

`undef CONFIGURE_VALID
`undef FOR_EVERY_PAGE
`undef RESET_WHEN_FIRE

endmodule
