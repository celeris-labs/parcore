`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import libstf::INT16_T;
import libstf::INT32_T;
import libstf::INT64_T;
import libstf::BYTE_T;
import libstf::GET_TYPE_WIDTH;
import parcore::*;

/**
 * The ColumnChunkDecoder without the path of PLAIN encoded values. They leave on plain_pages and come
 * back decoded on plain_values (data pages) and dict_values (dictionary pages). This way the
 * ColumnChunkDecoder for fixed-width types and the StringColumnChunkDecoder share everything else,
 * and only the latter pays for the string decoder on that path.
 */
module ColumnChunkDecoderCore #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf,         // #(column_chunk_conf_t)

    ndata_i.s       in,           // #(data8_t, DATABEAT_SIZE) raw column-chunk bytes
    ndata_i.m       out,          // #(DATABEAT_SIZE)

    ready_valid_i.m page_info,    // #(page_info_t)
    ndata_i.m       plain_pages,  // #(data8_t, DATABEAT_SIZE) PLAIN encoded values of a page
    ndata_i.s       plain_values, // #(data8_t, DATABEAT_SIZE) values of data pages
    ndata_i.s       dict_values,  // #(data8_t, DATABEAT_SIZE) values of dictionary pages

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
localparam int NUM_IN = 2;
typedef enum logic {
    IN_HYBRID = 0,
    IN_PLAIN  = 1
} in_selector_t;

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

ready_valid_i #(logic) plain_required_conf (clk, reset_synced); // is_required
StripLevels #(
    .NUM_BYTES(DATABEAT_SIZE)
) inst_strip_levels (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(plain_required_conf),

    .in(plain_in),
    .out(plain_stripped)
);

`DATA_ASSIGN(plain_stripped, plain_pages)

// 64 bit values cast to a narrower integer type are narrowed to INT32_T on the plain and dictionary
// paths, so the dictionary holds them in one entry. The logical cast at the output narrows further.
ready_valid_i #(type_t) plain_type_conf(clk, reset_synced), plain_cast_conf(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) plain_physical(clk, reset_synced);

NDataToTypedNData #(DATABEAT_SIZE) inst_plain_type (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(plain_type_conf),
    .in(plain_values),

    .out(plain_physical)
);

// ------ Dictionary Encoded Path ---------------
// With defer_dict_decoding, the dictionary page's values and the indices go to the output instead
// of the dictionary
typedef enum logic {
    TO_DICTIONARY = 0,
    TO_OUTPUT     = 1
} dict_dest_t;

ready_valid_i #(dict_dest_t) dict_dest_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) dict_dests[2](clk, reset_synced);
DataDemultiplexer #(2) inst_dict_demux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(dict_dest_conf),

    .in(dict_values),
    .out(dict_dests)
);

ready_valid_i #(type_t) dict_type_conf(clk, reset_synced), dict_cast_conf(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) dict_physical(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) dict_narrowed(clk, reset_synced);

NDataToTypedNData #(DATABEAT_SIZE) inst_dict_type (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(dict_type_conf),
    .in(dict_dests[TO_DICTIONARY]),

    .out(dict_physical)
);

TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_dict_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(dict_cast_conf),

    .in(dict_physical),
    .out(dict_narrowed)
);

// Registers the handover, so the RunDecoder's ready does not reach into the Decompressor
ndata_i #(data8_t, DATABEAT_SIZE) hybrid_in(clk, reset_synced);
NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_hybrid_in_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(ins[IN_HYBRID]),
    .out(hybrid_in)
);

data_i #(hybrid_page_conf_t) hybrid_page_decoder_conf(clk, reset_synced);
ndata_i #(id_t, NUM_DICT_ELEM) hybrid_ids(clk, reset_synced);
HybridPageDecoder #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM),
    .NUM_BYTES(DATABEAT_SIZE)
) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(hybrid_page_decoder_conf),

    .in(hybrid_in),
    .out(hybrid_ids)
);

ready_valid_i #(dict_dest_t) ids_dest_conf(clk, reset_synced);
ndata_i #(id_t, NUM_DICT_ELEM) ids_dests[2](clk, reset_synced);
DataDemultiplexer #(2) inst_ids_demux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(ids_dest_conf),

    .in(hybrid_ids),
    .out(ids_dests)
);

typed_ndata_i #(DATABEAT_SIZE) dict_out(clk, reset_synced);
TypedDictionary #(
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_dictionary (
    .clk(clk),
    .rst_n(reset_synced),

    .in_values(dict_narrowed),
    .in_ids(ids_dests[TO_DICTIONARY]),

    .out(dict_out)
);

// ------ Deferred dictionary decoding ---------------
// The HybridPageDecoder emits a single last per chunk, but the output multiplexer switches per page
ready_valid_i #(data32_t) ids_num_values_conf(clk, reset_synced);
ndata_i #(id_t, NUM_DICT_ELEM) ids_paged(clk, reset_synced);
DataRewriteLast #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM)
) inst_ids_rewrite_last (
    .clk(clk),
    .rst_n(reset_synced),

    .num_elements(ids_num_values_conf),

    .in(ids_dests[TO_OUTPUT]),
    .out(ids_paged)
);

// The RunDecoder ends a beat at every run, so the indices are packed densely for the cast
ndata_i #(id_t, NUM_DICT_ELEM) ids_normalized(clk, reset_synced);
DataNormalizer #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_DICT_ELEM)
) inst_ids_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(ids_paged),
    .out(ids_normalized)
);

`ASSERT_ELAB(NUM_DICT_ELEM * 4 == DATABEAT_SIZE)
typed_ndata_i #(DATABEAT_SIZE) ids_typed(clk, reset_synced), ids_narrowed(clk, reset_synced);
for (genvar I = 0; I < NUM_DICT_ELEM; I++) begin
    assign ids_typed.data[4 * I +: 4] = data32_t'(ids_normalized.data[I]);
    assign ids_typed.keep[4 * I +: 4] = {4{ids_normalized.keep[I]}};
end
assign ids_typed.typ        = INT32_T;
assign ids_typed.last       = ids_normalized.last;
assign ids_typed.valid      = ids_normalized.valid;
assign ids_normalized.ready = ids_typed.ready;

// Narrows the indices to 1, 2 or 4 bytes
ready_valid_i #(type_t) ids_type_conf(clk, reset_synced);
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_ids_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(ids_type_conf),

    .in(ids_typed),
    .out(ids_narrowed)
);

// ------ Output Multiplexing ---------------
localparam int NUM_OUT = 4;
typedef enum logic [1:0] {
  OUT_PLAIN  = 0,
  OUT_HYBRID = 1,
  OUT_DICT   = 2,
  OUT_IDS    = 3
} out_selector_t;
`ASSERT_ELAB(NUM_OUT <= 2**$bits(out_selector_t))
typed_ndata_i #(DATABEAT_SIZE) outs[NUM_OUT](clk, reset_synced);

TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_plain_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(plain_cast_conf),

    .in(plain_physical),
    .out(outs[OUT_PLAIN])
);

// The TypedDictionary emits one last per dictionary, but the output multiplexer switches per page
ready_valid_i #(data32_t) rewrite_last_conf(clk, reset_synced);
TypedRewriteLast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_hybrid_rewrite_last (
    .clk(clk),
    .rst_n(reset_synced),

    .num_elements(rewrite_last_conf),

    .in(dict_out),
    .out(outs[OUT_HYBRID])
);

// The deferred output is a byte stream, so the TypedNormalizeUntil counts its bytes
assign outs[OUT_DICT].data  = dict_dests[TO_OUTPUT].data;
assign outs[OUT_DICT].typ   = BYTE_T;
assign outs[OUT_DICT].keep  = dict_dests[TO_OUTPUT].keep;
assign outs[OUT_DICT].last  = dict_dests[TO_OUTPUT].last;
assign outs[OUT_DICT].valid = dict_dests[TO_OUTPUT].valid;
assign dict_dests[TO_OUTPUT].ready = outs[OUT_DICT].ready;

assign outs[OUT_IDS].data  = ids_narrowed.data;
assign outs[OUT_IDS].typ   = BYTE_T;
assign outs[OUT_IDS].keep  = ids_narrowed.keep;
assign outs[OUT_IDS].last  = ids_narrowed.last;
assign outs[OUT_IDS].valid = ids_narrowed.valid;
assign ids_narrowed.ready  = outs[OUT_IDS].ready;

ready_valid_i #(out_selector_t) out_mux_conf(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) per_page_out(clk, reset_synced);
TypedNDataMultiplexer #(DATABEAT_SIZE, NUM_OUT) inst_out_mux (
    .clk(clk),
    .rst_n(reset_synced),

    .select(out_mux_conf),

    .in(outs),
    .out(per_page_out)
);

ready_valid_i #(data32_t) normalize_until_conf(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) per_cc_out(clk, reset_synced);
TypedNormalizeUntil #(
    .size_t(data32_t),
    .DATABEAT_SIZE(DATABEAT_SIZE),
    .BARREL_SHIFTER_REGISTER_LEVELS(2)
) inst_normalize_until (
    .clk(clk),
    .rst_n(reset_synced),

    .size(normalize_until_conf),

    .in(per_page_out),
    .out(per_cc_out)
);

// Needs the dense input the TypedNormalizeUntil provides
ready_valid_i #(type_t) logical_type_conf(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) per_cc_logical(clk, reset_synced);
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_logical_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(logical_type_conf),

    .in(per_cc_out),
    .out(per_cc_logical)
);

`DATA_ASSIGN(per_cc_logical, out)

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

column_chunk_conf_t cc_conf_latched;
page_conf_t page_conf_r;

logic all_modules_consumed_configs;

always_ff @( posedge clk )
if (!reset_synced) begin
    state <= WAIT_FOR_CC_CONF;
    first_page <= 1;
    dict_page_seen <= 0;
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
                end else begin
                    state <= WAIT_FOR_PAGE_CONF;
                    first_page <= 0;
                    dict_page_seen <=
                            dict_page_seen || page_conf_r.page_type == PAGE_TYPE_DICT;
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

// ------ Deferred dictionary decoding ---------------------------------------
logic defer_dict;
assign defer_dict = cc_conf_latched.defer_dict_decoding;

function automatic type_t index_type(data32_t num_entries);
    if (num_entries <= 256) begin
        return BYTE_T;
    end else if (num_entries <= 65536) begin
        return INT16_T;
    end
    return INT32_T;
endfunction

// The dictionary page's values followed by one index per value
function automatic data32_t deferred_output_size(type_t typ, data32_t num_entries, data32_t num_values);
    data32_t dictionary_bytes, index_bytes;
    case (GET_TYPE_WIDTH(typ))
        128:     dictionary_bytes = num_entries << 4;
        64:      dictionary_bytes = num_entries << 3;
        default: dictionary_bytes = num_entries << 2;
    endcase
    case (index_type(num_entries))
        BYTE_T:  index_bytes = num_values;
        INT16_T: index_bytes = num_values << 1;
        default: index_bytes = num_values << 2;
    endcase
    return dictionary_bytes + index_bytes;
endfunction

type_t index_typ; // Of the chunk's dictionary page
always_ff @( posedge clk ) begin
    if (state == CONFIGURE && page_conf_r.page_type == PAGE_TYPE_DICT) begin
        index_typ <= index_type(page_conf_r.num_values);
    end
end

ready_valid_i #(dict_dest_t) _dict_dest_conf (clk, reset_synced);
ready_valid_i #(dict_dest_t) _ids_dest_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_dict_dests
    _dict_dest_conf.valid <= n_conf_valid(_dict_dest_conf.valid, _dict_dest_conf.ready, page_conf_r.page_type == PAGE_TYPE_DICT);
    _ids_dest_conf.valid  <= n_conf_valid(_ids_dest_conf.valid, _ids_dest_conf.ready, page_conf_r.page_type == PAGE_TYPE_DICT);
    _dict_dest_conf.data  <= defer_dict ? TO_OUTPUT : TO_DICTIONARY;
    _ids_dest_conf.data   <= defer_dict ? TO_OUTPUT : TO_DICTIONARY;
end
SkidBuffer #(dict_dest_t) inst_dict_dest_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_dict_dest_conf), .out(dict_dest_conf));
SkidBuffer #(dict_dest_t) inst_ids_dest_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_ids_dest_conf), .out(ids_dest_conf));

ready_valid_i #(data32_t) _ids_num_values_conf (clk, reset_synced);
ready_valid_i #(type_t) _ids_type_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_ids_output
    _ids_num_values_conf.valid <= n_conf_valid(_ids_num_values_conf.valid, _ids_num_values_conf.ready, defer_dict && page_conf_r.page_type == PAGE_TYPE_HYBRID);
    _ids_type_conf.valid       <= n_conf_valid(_ids_type_conf.valid, _ids_type_conf.ready, defer_dict && page_conf_r.page_type == PAGE_TYPE_HYBRID);
    _ids_num_values_conf.data  <= page_conf_r.num_values;
    _ids_type_conf.data        <= index_typ;
end
SkidBuffer #(data32_t) inst_ids_num_values_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_ids_num_values_conf), .out(ids_num_values_conf));
SkidBuffer #(type_t) inst_ids_type_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_ids_type_conf), .out(ids_type_conf));

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
SkidBuffer #(compression_t) inst_decompressor_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_decompressor_conf), .out(decompressor_conf));

ready_valid_i #(in_selector_t) _data_page_path_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_data_page_path
    _data_page_path_conf.valid <= n_conf_valid(
        _data_page_path_conf.valid,
        _data_page_path_conf.ready,
        FOR_EVERY_PAGE
    );
    _data_page_path_conf.data <= page_conf_r.page_type == PAGE_TYPE_HYBRID ? IN_HYBRID : IN_PLAIN;
end
SkidBuffer #(in_selector_t) inst_data_page_path_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_data_page_path_conf), .out(data_page_path_conf));


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

data_i #(hybrid_page_conf_t) _hybrid_page_decoder_conf (clk, reset_synced);
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
    _hybrid_page_decoder_conf.data.num_values  <= hybrid_flush ? '0 : page_conf_r.num_values;
    _hybrid_page_decoder_conf.data.is_required <= cc_conf_latched.is_required;
    _hybrid_page_decoder_conf.keep <= ~hybrid_flush;
    _hybrid_page_decoder_conf.last <= page_conf_r.last;
end
DataSkidBuffer #(hybrid_page_conf_t) inst_hybrid_page_decoder_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_hybrid_page_decoder_conf), .out(hybrid_page_decoder_conf));

ready_valid_i #(data32_t) _rewrite_last_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_rewrite_last
    _rewrite_last_conf.valid <= n_conf_valid(
        _rewrite_last_conf.valid,
        _rewrite_last_conf.ready,
        !defer_dict && page_conf_r.page_type == PAGE_TYPE_HYBRID
    );
    _rewrite_last_conf.data <= page_conf_r.num_values;
end
SkidBuffer #(data32_t) inst_rewrite_last_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_rewrite_last_conf), .out(rewrite_last_conf));

// ------ PLAIN encoded values configuration ---------------------------------------
logic plain_encoded_page;
assign plain_encoded_page = page_conf_r.page_type != PAGE_TYPE_HYBRID;

ready_valid_i #(page_info_t) _page_info (clk, rst_n);
always_ff @( posedge clk ) begin : configure_page_info
    _page_info.valid <= n_conf_valid(
        _page_info.valid,
        _page_info.ready,
        FOR_EVERY_PAGE
    );
    _page_info.data <= '{
        typ:        cc_conf_latched.typ,
        page_type:  page_conf_r.page_type,
        first_page: first_page,
        last:       page_conf_r.last
    };
end
SkidBuffer #(page_info_t) inst_page_info_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_page_info), .out(page_info));

// ------ Output MUX control ---------------------------------------
ready_valid_i #(out_selector_t) _out_mux_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_out_mux
    _out_mux_conf.valid <= n_conf_valid(
        _out_mux_conf.valid,
        _out_mux_conf.ready,
        defer_dict || page_conf_r.page_type != PAGE_TYPE_DICT
    );
    case (page_conf_r.page_type)
        PAGE_TYPE_HYBRID: _out_mux_conf.data <= defer_dict ? OUT_IDS : OUT_HYBRID;
        PAGE_TYPE_DICT:   _out_mux_conf.data <= OUT_DICT;
        default:          _out_mux_conf.data <= OUT_PLAIN;
    endcase
end
SkidBuffer #(out_selector_t) inst_out_mux_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_out_mux_conf), .out(out_mux_conf));

// ------ Plain Page level configuration ---------------------------------------
// Dictionary pages have no levels, so StripLevels forwards them like pages of a REQUIRED column
ready_valid_i #(logic) _plain_required_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_plain_required
    _plain_required_conf.valid <= n_conf_valid(
        _plain_required_conf.valid,
        _plain_required_conf.ready,
        plain_encoded_page
    );
    _plain_required_conf.data <= cc_conf_latched.is_required ||
                                 page_conf_r.page_type == PAGE_TYPE_DICT;
end
SkidBuffer #(logic) inst_plain_required_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_plain_required_conf), .out(plain_required_conf));

// ------ Column Chunk level configurations ---------------------------------------
ready_valid_i #(data32_t) _normalize_until_conf (clk, rst_n);
always_ff @( posedge clk ) begin : configure_normalize_until
    _normalize_until_conf.valid <= n_conf_valid(
        _normalize_until_conf.valid,
        _normalize_until_conf.ready,
        first_page
    );
    // A defer_dict_decoding chunk starts with its dictionary page
    _normalize_until_conf.data <= defer_dict ?
        deferred_output_size(cc_conf_latched.typ, page_conf_r.num_values, cc_conf_latched.num_values) :
        cc_conf_latched.num_values;
end
SkidBuffer #(data32_t) inst_normalize_until_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_normalize_until_conf), .out(normalize_until_conf));

type_t path_typ;
assign path_typ = cc_conf_latched.typ == INT64_T &&
                  cc_conf_latched.logical_typ inside {INT32_T, INT16_T, BYTE_T} ?
                  INT32_T : cc_conf_latched.typ;

ready_valid_i #(type_t) _plain_type_conf (clk, reset_synced);
ready_valid_i #(type_t) _plain_cast_conf (clk, reset_synced);
ready_valid_i #(type_t) _dict_type_conf (clk, reset_synced);
ready_valid_i #(type_t) _dict_cast_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_path_types
    _plain_type_conf.valid <= n_conf_valid(_plain_type_conf.valid, _plain_type_conf.ready, page_conf_r.page_type == PAGE_TYPE_PLAIN);
    _plain_cast_conf.valid <= n_conf_valid(_plain_cast_conf.valid, _plain_cast_conf.ready, page_conf_r.page_type == PAGE_TYPE_PLAIN);
    _dict_type_conf.valid  <= n_conf_valid(_dict_type_conf.valid, _dict_type_conf.ready, !defer_dict && page_conf_r.page_type == PAGE_TYPE_DICT);
    _dict_cast_conf.valid  <= n_conf_valid(_dict_cast_conf.valid, _dict_cast_conf.ready, !defer_dict && page_conf_r.page_type == PAGE_TYPE_DICT);
    _plain_type_conf.data  <= cc_conf_latched.typ;
    _plain_cast_conf.data  <= path_typ;
    _dict_type_conf.data   <= cc_conf_latched.typ;
    _dict_cast_conf.data   <= path_typ;
end
SkidBuffer #(type_t) inst_plain_type_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_plain_type_conf), .out(plain_type_conf));
SkidBuffer #(type_t) inst_plain_cast_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_plain_cast_conf), .out(plain_cast_conf));
SkidBuffer #(type_t) inst_dict_type_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_dict_type_conf), .out(dict_type_conf));
SkidBuffer #(type_t) inst_dict_cast_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_dict_cast_conf), .out(dict_cast_conf));

ready_valid_i #(type_t) _logical_type_conf (clk, reset_synced);
always_ff @( posedge clk ) begin : configure_logical_type
    _logical_type_conf.valid <= n_conf_valid(_logical_type_conf.valid, _logical_type_conf.ready, first_page);
    _logical_type_conf.data  <= defer_dict ? BYTE_T : cc_conf_latched.logical_typ;
end
SkidBuffer #(type_t) inst_logical_type_conf_skid_buffer (.clk(clk), .rst_n(rst_n), .in(_logical_type_conf), .out(logical_type_conf));

assign all_modules_consumed_configs =
        !_decompressor_conf.valid &&
        !_data_page_path_conf.valid &&
        !_hybrid_page_decoder_conf.valid &&
        !_page_info.valid &&
        !_rewrite_last_conf.valid &&
        !_out_mux_conf.valid &&
        !_normalize_until_conf.valid &&
        !_plain_required_conf.valid &&
        !_plain_type_conf.valid &&
        !_plain_cast_conf.valid &&
        !_dict_type_conf.valid &&
        !_dict_cast_conf.valid &&
        !_logical_type_conf.valid &&
        !_dict_dest_conf.valid &&
        !_ids_dest_conf.valid &&
        !_ids_num_values_conf.valid &&
        !_ids_type_conf.valid;
assign chunk_confs[0].ready = state == WAIT_FOR_CC_CONF;
assign page_conf.ready = state == WAIT_FOR_PAGE_CONF;

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced)
    !(state == CONFIGURE && defer_dict && page_conf_r.page_type == PAGE_TYPE_PLAIN))
else $fatal(1, "ColumnChunkDecoderCore got a PLAIN data page in a defer_dict_decoding chunk");

assert property (@(posedge clk) disable iff (!reset_synced)
    !(state == CONFIGURE && defer_dict && first_page && page_conf_r.page_type != PAGE_TYPE_DICT))
else $fatal(1, "ColumnChunkDecoderCore got a defer_dict_decoding chunk without a dictionary page");
`endif

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

endmodule
