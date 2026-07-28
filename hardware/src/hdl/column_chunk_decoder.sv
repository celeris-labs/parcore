`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import libstf::vaddress_t;
import libstf::german_str_t;
import libstf::BYTE_T;
import libstf::INT32_T;
import libstf::INT64_T;
import libstf::FLOAT_T;
import libstf::DOUBLE_T;
import libstf::GERMAN_STR_T;
import parcore::*;

module ColumnChunkDecoder #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8,
    parameter type id_t = data32_t
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
localparam NUM_ELEMS_SMALLES_ELEM = max(8, DATABEAT_SIZE / ($bits(data32_t) / 8));
// Number of string elements per data beat
localparam NUM_STR_IDS = DATABEAT_SIZE / ($bits(german_str_t) / 8);

// ------ Page Level Config Chain -----------------
ready_valid_i #(page_type_info_t) page_level_config_chain[4] (clk, rst_n);


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
ready_valid_i #(compression_t) _decompressor_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) decompressor_out(clk, reset_synced);
Decompressor #(DATABEAT_SIZE) inst_decompressor (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(_decompressor_conf),

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

ready_valid_i #(in_selector_t) in_select(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) ins[NUM_IN](clk, reset_synced);
DataDemultiplexer #(NUM_IN) inst_multiplexer (
    .clk(clk),
    .rst_n(reset_synced),

    .select(in_select),

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
logic plain_stripped_select;

StripLevels #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_strip_levels (
    .clk(clk),
    .rst_n(reset_synced),

    .in(plain_in),
    .out(plain_stripped)
);

ready_valid_i #(page_type_info_t) plain_router_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) stripped_to_plain (clk, rst_n);
`DATA_ASSIGN(plain_stripped, stripped_to_plain)
ndata_i #(data8_t, DATABEAT_SIZE) str_decoder_to_plain (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_to_str_decoder (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) plain_to_out (clk, rst_n);
PlainRouter #(DATABEAT_SIZE) inst_values_router (
    .clk (clk),
    .rst_n (rst_n),

    .page_conf (plain_router_conf),

    .in_from_stripped (stripped_to_plain),
    .in_from_str_decoder (str_decoder_to_plain),

    .out_to_str_decoder (plain_to_str_decoder),
    .out_values (plain_to_out)
);

// ------ German String Decoder ---------------

ready_valid_i #(plain_str_decoder_conf_t) plain_str_decoder_conf (clk, rst_n);
ready_valid_i #(plain_str_decoder_conf_t) _plain_str_decoder_conf (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_in (clk, rst_n);
// The decoder emits one german string per beat; the router moves full beats.
data_i #(german_str_t) psd_out_strings (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_strings_packed (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) psd_out_heap (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) dict_body_to_str_decoder (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) str_decoder_to_dict_body (clk, rst_n);
PlainStringDecoder #(DATABEAT_SIZE) inst_psd (
    .clk (clk),
    .rst_n (rst_n),

    .conf (_plain_str_decoder_conf),

    .in_data (psd_in),
    .out_strings (psd_out_strings),
    .out_data (psd_out_heap)
);

// Raw bytes of german strings longer than 12 bytes, written to the string heap.
// The decoder emits one packet per page, but it walks its heap pointer as if the
// pages were contiguous, so the pages have to be packed into a single chunk-wide
// packet - otherwise every page after the first hands out addresses shifted by
// the previous page's tail padding.
ready_valid_i #(logic[1:0])       heap_conf   (clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) heap_packed (clk, reset_synced);

HeapNormalizer #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_heap_normalizer (
    .clk (clk),
    .rst_n (reset_synced),

    .conf (heap_conf),

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

    .page_conf (str_router_conf),

    .in_from_plain (plain_to_str_decoder),
    .in_from_dict_body (dict_body_to_str_decoder),
    .out_to_str_decoder (psd_in),

    .in_from_str_decoder (psd_strings_packed),
    .out_to_plain (str_decoder_to_plain),
    .out_to_dict_body (str_decoder_to_dict_body)
);

// ------ Dictionary Page Path ---------------
ndata_i #(data8_t, DATABEAT_SIZE) dict_body_to_dict (clk, rst_n);
ready_valid_i #(type_t) dict_body_dtype (clk, reset_synced);
DictionaryBody #(DATABEAT_SIZE) inst_dict_body (
    .clk (clk),
    .rst_n (reset_synced),

    .dtype (dict_body_dtype),

    .in_body (ins[IN_DICT]),
    .in_german_strings (str_decoder_to_dict_body),

    .out_to_psd (dict_body_to_str_decoder),
    .out_to_dict (dict_body_to_dict)
);


// ------ Dictionary Encoded Path ---------------
data_i #(data32_t) hybrid_conf(clk, reset_synced);
data_i #(data32_t) _hybrid_conf(clk, reset_synced);
ndata_i #(id_t, NUM_ELEMS_SMALLES_ELEM) dict_ids_native (clk, reset_synced);
HybridPageDecoder #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMS_SMALLES_ELEM),
    .NUM_BYTES(DATABEAT_SIZE)
) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(_hybrid_conf),

    .in(ins[IN_HYBRID]),
    .out(dict_ids_native)
);

ready_valid_i #(type_t) dictionary_body_dtype (clk, rst_n);
ndata_i #(id_t, NUM_ELEMS_SMALLES_ELEM) dict_ids_scaled (clk, reset_synced);
DictionaryID #(
    id_t,
    NUM_ELEMS_SMALLES_ELEM
) inst_index_conversion (
    .clk(clk),
    .rst_n(reset_synced),

    .dtype (dictionary_body_dtype),

    .in (dict_ids_native),
    .out (dict_ids_scaled)
);

// The Dictionary indexes 32-bit values while the rest of the path moves bytes.
// Both carry 512 bits per beat, so the adapters below only regroup keep.
ndata_i #(data32_t, NUM_ELEMS_SMALLES_ELEM) dict_in_values  (clk, reset_synced);
ndata_i #(data32_t, NUM_ELEMS_SMALLES_ELEM) dict_out_values (clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) dict_decoded_bytes (.*);

assign dict_in_values.data     = dict_body_to_dict.data;
assign dict_in_values.last     = dict_body_to_dict.last;
assign dict_in_values.valid    = dict_body_to_dict.valid;
assign dict_body_to_dict.ready = dict_in_values.ready;

assign dict_decoded_bytes.data  = dict_out_values.data;
assign dict_decoded_bytes.last  = dict_out_values.last;
assign dict_decoded_bytes.valid = dict_out_values.valid;
assign dict_out_values.ready    = dict_decoded_bytes.ready;

for (genvar I = 0; I < NUM_ELEMS_SMALLES_ELEM; I++) begin
    assign dict_in_values.keep[I] = &dict_body_to_dict.keep[4*I +: 4];
    assign dict_decoded_bytes.keep[4*I +: 4] = {4{dict_out_values.keep[I]}};
end

Dictionary #(
    .value_t(data32_t),
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMS_SMALLES_ELEM)
) inst_dictionary (
    .clk(clk),
    .rst_n(reset_synced),

    .in_values(dict_in_values),
    .in_ids(dict_ids_scaled),

    .out(dict_out_values)
);

ready_valid_i #(data32_t) last_rewrite_page_elems (clk, rst_n);
ready_valid_i #(data32_t) _last_rewrite_page_elems (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) hybrid_path_out (.*);
DataRewriteLast #(
    .data_t(data8_t),
    .NUM_ELEMENTS (DATABEAT_SIZE)
) inst_reinsert_last_for_hybrid_path (
    .clk (clk),
    .rst_n (rst_n),

    .num_elements (_last_rewrite_page_elems),

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

ready_valid_i #(logic) out_mux_select (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) per_page_out(clk, reset_synced);
DataMultiplexer #(
    data8_t,
    DATABEAT_SIZE,
    NUM_OUT
) inst_out_mux (
    .clk (clk),
    .rst_n (rst_n),

    .select (out_mux_select),

    .in (outs),
    .out(per_page_out)
);

ready_valid_i #(data32_t) num_cc_values (clk, rst_n);
ready_valid_i #(data32_t) _num_cc_values (clk, rst_n);
ndata_i #(data8_t, DATABEAT_SIZE) per_cc_out (clk, reset_synced);
NormalizeUntil #(
    data8_t,
    data32_t,
    DATABEAT_SIZE
) inst_page_value_collector (
    .clk (clk),
    .rst_n (rst_n),

    .size (_num_cc_values),

    .in (per_page_out),
    .out (per_cc_out)
);

`DATA_ASSIGN(per_cc_out, out)

// ------------------------------------------------------------------
// ------ Config distribution ---------------------------------------
// ------------------------------------------------------------------
// Every sink sits behind a skid buffer, so one page config is handed to all of
// them in a single cycle and nothing has to be retired before the next page is
// accepted. Selects that do not apply to a page are simply not enqueued; each
// queue stays paired with its own stream because both advance once per page.

// ---- Page-level config chain (page_type_info_t, 5 bits) ----------
// stage 0 -> plain_router_conf, dictionary_body_dtype
// stage 1 -> str_router_conf
// stage 2 -> out_mux_select
// Each RegisteredReadyValidDuplicator registers its input, so the long haul
// from here to each router terminates on a flop at both ends.
ready_valid_i #(page_type_info_t) dict_dtype_conf (clk, reset_synced);
ready_valid_i #(type_t)           dict_dtype_pre  (clk, reset_synced);
ready_valid_i #(page_type_info_t) dict_body_conf  (clk, reset_synced);
ready_valid_i #(type_t)           dict_body_pre   (clk, reset_synced);
ready_valid_i #(logic)            out_mux_sel_pre (clk, reset_synced);
ready_valid_i #(in_selector_t)    in_select_pre   (clk, reset_synced);

// The input demultiplexer routes every page, keyed purely on its type.
assign in_select_pre.data  = in_selector_t'(page_conf.data.page_type);
assign in_select_pre.valid = page_conf_fire;

SkidBuffer #(in_selector_t) inst_in_select_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(in_select_pre),
    .out(in_select)
);

RegisteredReadyValidDuplicator #(page_type_info_t, 4) inst_page_conf_fan_0 (
    .clk(clk),
    .rst_n(reset_synced),

    .in(page_level_config_chain[0]),
    .out({plain_router_conf, dict_dtype_conf, dict_body_conf,
          page_level_config_chain[1]})
);

RegisteredReadyValidDuplicator #(page_type_info_t, 2) inst_page_conf_fan_1 (
    .clk(clk),
    .rst_n(reset_synced),

    .in(page_level_config_chain[1]),
    .out({str_router_conf, page_level_config_chain[2]})
);

SkidBuffer #(page_type_info_t) inst_page_conf_reg_2 (
    .clk(clk),
    .rst_n(reset_synced),

    .in(page_level_config_chain[2]),
    .out(page_level_config_chain[3])
);

// DictionaryID rescales one index stream per hybrid page.
assign dict_dtype_pre.data   = dict_dtype_conf.data.typ;
assign dict_dtype_pre.valid  = dict_dtype_conf.valid
                            && dict_dtype_conf.data.ptyp == PAGE_TYPE_HYBRID;
assign dict_dtype_conf.ready = dict_dtype_pre.ready;

SkidBuffer #(type_t) inst_dict_dtype_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(dict_dtype_pre),
    .out(dictionary_body_dtype)
);

// DictionaryBody routes one body per dictionary page.
assign dict_body_pre.data   = dict_body_conf.data.typ;
assign dict_body_pre.valid  = dict_body_conf.valid
                           && dict_body_conf.data.ptyp == PAGE_TYPE_DICT;
assign dict_body_conf.ready = dict_body_pre.ready;

SkidBuffer #(type_t) inst_dict_body_dtype_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(dict_body_pre),
    .out(dict_body_dtype)
);

// Dictionary pages emit no values, so they get no output-mux select.
assign out_mux_sel_pre.data  =
    page_level_config_chain[3].data.ptyp == PAGE_TYPE_HYBRID ? OUT_HYBRID
                                                             : OUT_PLAIN;
assign out_mux_sel_pre.valid = page_level_config_chain[3].valid
                            && page_level_config_chain[3].data.ptyp != PAGE_TYPE_DICT;
assign page_level_config_chain[3].ready = out_mux_sel_pre.ready;

SkidBuffer #(logic) inst_out_mux_sel_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(out_mux_sel_pre),
    .out(out_mux_select)
);

// ---- Skid buffers for the directly driven sinks ------------------
`SKID_SIGNAL(compression_t, clk, reset_synced, decompressor_conf, _decompressor_conf)
`SKID_SIGNAL(plain_str_decoder_conf_t, clk, reset_synced, plain_str_decoder_conf, _plain_str_decoder_conf)
`SKID_SIGNAL(data32_t, clk, reset_synced, last_rewrite_page_elems, _last_rewrite_page_elems)
`SKID_SIGNAL(data32_t, clk, reset_synced, num_cc_values, _num_cc_values)

DataSkidBuffer #(data32_t) inst_hybrid_conf_skid (
    .clk(clk),
    .rst_n(reset_synced),

    .in(hybrid_conf),
    .out(_hybrid_conf)
);

// ---- Chunk-level context -----------------------------------------
typedef enum logic {
    ST_IDLE,
    ST_CONFIGURED
} state_t;
state_t state;

// A column chunk carries a single data type, so the dtype half of
// page_type_info_t comes from the chunk config, not from page_conf_t.
compression_t cc_compression;
type_t        cc_typ;
vaddress_t    cc_heap_addr_base;
vaddress_t    cc_heap_addr;

logic page_conf_fire;
assign page_conf_fire = page_conf.valid && page_conf.ready;

// A page is only taken once every queue it feeds has room. All of these readies
// come out of skid-buffer state, never from a valid, so this is not a loop.
assign page_conf.ready = (state == ST_CONFIGURED)
                      && in_select_pre.ready
                      && decompressor_conf.ready
                      && plain_str_decoder_conf.ready
                      && last_rewrite_page_elems.ready
                      && hybrid_conf.ready
                      && heap_conf.ready
                      && page_level_config_chain[0].ready;

assign chunk_confs[0].ready = (state == ST_IDLE) && num_cc_values.ready;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        state <= ST_IDLE;
    end else begin
        case (state)
            ST_IDLE: begin
                if (chunk_confs[0].valid && chunk_confs[0].ready) begin
                    cc_compression <= chunk_confs[0].data.compression;
                    cc_typ         <= chunk_confs[0].data.typ;
                    state          <= ST_CONFIGURED;
                end
            end
            ST_CONFIGURED: begin
                if (page_conf_fire && page_conf.data.last) begin
                    state <= ST_IDLE;
                end
            end
        endcase
    end
end

// ---- Chunk-scoped config -----------------------------------------
// NormalizeUntil packs across page boundaries until the chunk's value count is
// reached, so it is configured once per chunk rather than per page.
// NormalizeUntil and DataRewriteLast both count stream elements, and the output
// path is byte granular, so the value counts are scaled to bytes here.
logic [2:0] typ_shift;
always_comb begin
    case (cc_typ)
        INT32_T, FLOAT_T:  typ_shift = 3'd2;
        INT64_T, DOUBLE_T: typ_shift = 3'd3;
        GERMAN_STR_T:      typ_shift = 3'd4;
        default:           typ_shift = 3'd0; // BYTE_T
    endcase
end

// The chunk config has not been latched yet when this fires, so it is scaled
// with the type coming straight off the config rather than with cc_typ.
logic [2:0] cc_typ_shift;
always_comb begin
    case (chunk_confs[0].data.typ)
        INT32_T, FLOAT_T:  cc_typ_shift = 3'd2;
        INT64_T, DOUBLE_T: cc_typ_shift = 3'd3;
        GERMAN_STR_T:      cc_typ_shift = 3'd4;
        default:           cc_typ_shift = 3'd0; // BYTE_T
    endcase
end

assign num_cc_values.data  = chunk_confs[0].data.num_values << cc_typ_shift;
assign num_cc_values.valid = chunk_confs[0].valid && (state == ST_IDLE);

// ---- Per-page config ---------------------------------------------
assign page_level_config_chain[0].data.typ  = cc_typ;
assign page_level_config_chain[0].data.ptyp = page_conf.data.page_type;
assign page_level_config_chain[0].valid     = page_conf_fire;

assign decompressor_conf.data  = cc_compression;
assign decompressor_conf.valid = page_conf_fire;

// DataRewriteLast re-injects a per-page last on the hybrid path only.
assign last_rewrite_page_elems.data  = page_conf.data.num_values << typ_shift;
assign last_rewrite_page_elems.valid = page_conf_fire
                                    && page_conf.data.page_type == PAGE_TYPE_HYBRID;

// ---- PlainStringDecoder config -----------------------------------
// The decoder walks its own heap pointer once it has a base, so the chunk's
// heap base is latched on the first page of the chunk and reused for the rest.
logic psd_first_page;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        psd_first_page <= 1'b1;
    end else begin
        // The chunk config is long retired by the time pages arrive, so the base
        // address is captured with it and handed to the first page of the chunk.
        if (chunk_confs[0].valid && chunk_confs[0].ready) begin
            cc_heap_addr_base <= chunk_confs[0].data.string_heap_addr;
        end

        if (page_conf_fire) begin
            // The page after a chunk's last page opens the next chunk.
            psd_first_page <= page_conf.data.last;

            if (psd_first_page) begin
                cc_heap_addr <= cc_heap_addr_base;
            end
        end
    end
end

assign plain_str_decoder_conf.data.update_buffer_addr = psd_first_page;
assign plain_str_decoder_conf.data.num_values         = page_conf.data.num_values;
assign plain_str_decoder_conf.data.buffer_addr        = cc_heap_addr_base;
assign plain_str_decoder_conf.valid = page_conf_fire
                                   && cc_typ == GERMAN_STR_T
                                   && page_conf.data.page_type != PAGE_TYPE_HYBRID;

// ---- HeapNormalizer config ---------------------------------------
// One entry per page of a string chunk: {generates_heap, last_page}. Pages that
// reach the decoder contribute bytes; HYBRID pages contribute none but still take
// an entry, so the chunk's final page always carries the flush even when it emits
// no heap of its own. Other chunks enqueue nothing and leave the heap silent.
assign heap_conf.data  = {page_conf.data.page_type != PAGE_TYPE_HYBRID,
                          page_conf.data.last};
assign heap_conf.valid = page_conf_fire && cc_typ == GERMAN_STR_T;

// ---- HybridPageDecoder config ------------------------------------
// A chunk that carried a dictionary page but ends on a plain page never sends a
// last beat down the hybrid path, so the Dictionary would hold its contents into
// the next chunk. Enqueue a dummy config with keep low and last high to flush it.
logic dict_seen;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        dict_seen <= 1'b0;
    end else if (page_conf_fire) begin
        if (page_conf.data.last) begin
            dict_seen <= 1'b0;
        end else if (page_conf.data.page_type == PAGE_TYPE_DICT) begin
            dict_seen <= 1'b1;
        end
    end
end

logic hybrid_flush;
assign hybrid_flush = dict_seen
                   && page_conf.data.last
                   && page_conf.data.page_type == PAGE_TYPE_PLAIN;

assign hybrid_conf.data  = hybrid_flush ? '0 : page_conf.data.num_values;
assign hybrid_conf.keep  = ~hybrid_flush;
assign hybrid_conf.last  = page_conf.data.last;
assign hybrid_conf.valid = page_conf_fire
                        && (hybrid_flush
                            || page_conf.data.page_type == PAGE_TYPE_HYBRID);

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

// `ifdef SYNTHESIS
// ila_page_decoder inst_ila_page_decoder (
//     .clk(clk),
//     .probe0(reset_synced),
//
//     .probe1(state),
//     .probe2(last_page),
//
//     .probe3(in_select.ready),
//     .probe4(in_select.valid),
//     .probe5(in_select.data),
//
//     .probe6(out_select.ready),
//     .probe7(out_select.valid),
//     .probe8(out_select.data),
//
//     .probe9(hybrid_conf.ready),
//     .probe10(hybrid_conf.valid),
//     .probe11(hybrid_conf.data),
//
//     .probe12(decompressor_out.ready),
//     .probe13(decompressor_out.valid),
//     .probe14(decompressor_out.last),
//     .probe15(decompressor_out.keep),
//
//     .probe16(ins[IN_HYBRID].ready),
//     .probe17(ins[IN_HYBRID].valid),
//     .probe18(decompressor_out.last),
//     .probe19(ins[IN_HYBRID].keep),
//
//     .probe20(hybrid_out.ready),
//     .probe21(hybrid_out.valid),
//
//     .probe22(out.ready),
//     .probe23(out.valid),
//     .probe24(out.keep),
//     .probe25(out.last),
//
//     .probe26(inner_out.ready),
//     .probe27(inner_out.valid),
//     .probe28(inner_out.keep),
//     .probe29(inner_out.last)
// );
// `endif

endmodule
