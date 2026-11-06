`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import libstf::BYTE_T;
import libstf::INT16_T;
import libstf::INT32_T;
import libstf::INT64_T;
import libstf::GET_TYPE_WIDTH;
import parcore::*;

module ColumnChunkDecoder #(
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // #(column_chunk_conf_t)

    ndata_i.s       in,  // #(data8_t, DATABEAT_SIZE) raw column-chunk bytes
    typed_ndata_i.m out, // #(DATABEAT_SIZE)

    decoder_profile_i.m profile
);

`RESET_RESYNC // Reset pipelining

localparam NUM_IDS = 16;

// ------ Multiplexing declarations ---------------
localparam int NUM_IN = 4;
typedef enum logic [$bits(page_type_t) - 1:0] {
    IN_HYBRID = PAGE_TYPE_HYBRID,
    IN_DICT = PAGE_TYPE_DICT,
    IN_PLAIN = PAGE_TYPE_PLAIN,
    IN_DICT_DEFERRED = 3
} in_selector_t;
`ASSERT_ELAB(NUM_IN <= 2**$bits(in_selector_t))

ndata_i #(data8_t, DATABEAT_SIZE) ins[NUM_IN](clk, reset_synced);

localparam int NUM_OUT = 4;
typedef enum logic [1:0] {
  OUT_HYBRID = 0,
  OUT_PLAIN = 1,
  OUT_DICT = 2,
  OUT_IDS = 3
} out_selector_t;
`ASSERT_ELAB(NUM_OUT <= 2**$bits(out_selector_t))
typed_ndata_i #(DATABEAT_SIZE) outs[NUM_OUT](clk, reset_synced);

ready_valid_i #(in_selector_t)  in_select(clk, reset_synced);
ready_valid_i #(out_selector_t) out_select(clk, reset_synced);

// ------ PageHeaderParser wiring -----------------
ready_valid_i #(column_chunk_conf_t) chunk_confs[2](clk, reset_synced);
ready_valid_i #(page_conf_t)         page_conf(clk, reset_synced);

ReadyValidDuplicator #(2) inst_chunk_conf_duplicator (
    .clk(clk),
    .rst_n(reset_synced),

    .in(conf),
    .out(chunk_confs)
);
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

// ------ Decompressor wiring ---------------------
ready_valid_i #(compression_t) decompressor_conf(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) decompressor_out(clk, reset_synced);
Decompressor #(DATABEAT_SIZE) inst_decompressor (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(decompressor_conf),

    .in(page_payload),
    .out(decompressor_out)
);

DataDemultiplexer #(NUM_IN) inst_multiplexer (
    .clk(clk),
    .rst_n(reset_synced),

    .select(in_select),

    .in(decompressor_out),
    .out(ins)
);

// ------ Hybrid decoder + dictionary wiring ------
data_i #(hybrid_page_conf_t) hybrid_conf(clk, reset_synced);

ndata_i #(id_t, NUM_IDS) hybrid_ids(clk, reset_synced);
HybridPageDecoder #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_IDS),
    .NUM_BYTES(DATABEAT_SIZE)
) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(hybrid_conf),
    .in(ins[IN_HYBRID]),

    .out(hybrid_ids)
);

localparam int NUM_IDS_OUT = 2;
typedef enum logic {
    IDS_DICTIONARY = 0,
    IDS_OUTPUT = 1
} ids_selector_t;

ready_valid_i #(ids_selector_t) ids_select(clk, reset_synced);
ndata_i #(id_t, NUM_IDS) ids_outs[NUM_IDS_OUT](clk, reset_synced);
DataDemultiplexer #(NUM_IDS_OUT) inst_ids_demultiplexer (
    .clk(clk),
    .rst_n(reset_synced),

    .select(ids_select),

    .in(hybrid_ids),
    .out(ids_outs)
);

ready_valid_i #(type_t) dict_type(clk, reset_synced), dict_cast_type(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) dict_physical(clk, reset_synced), dict_values(clk, reset_synced);
NDataToTypedNData #(DATABEAT_SIZE) inst_dict_typed_conversion (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(dict_type),
    .in(ins[IN_DICT]),

    .out(dict_physical)
);

// Narrows 64 bit values to INT32_T before they are stored, so the dictionary can look up twice as
// many per beat. Narrower logical types are cast further at the output, because the TypedDictionary
// only holds 32 and 64 bit values.
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_dict_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(dict_cast_type),

    .in(dict_physical),
    .out(dict_values)
);

typed_ndata_i #(DATABEAT_SIZE) hybrid_typed(clk, reset_synced);
TypedDictionary #(
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_IDS),
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_typed_dictionary (
    .clk(clk),
    .rst_n(reset_synced),

    .in_values(dict_values),
    .in_ids(ids_outs[IDS_DICTIONARY]),

    .out(hybrid_typed)
);

// The TypedDictionary emits a single `last` per dictionary (hybrid-page
// group), but the output multiplexer consumes out_select per page. This
// re-injects a per-page `last` after each page's num_values worth of values.
ready_valid_i #(data32_t) hybrid_num_values(clk, reset_synced);
TypedRewriteLast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_hybrid_set_last (
    .clk(clk),
    .rst_n(reset_synced),

    .num_elements(hybrid_num_values),

    .in(hybrid_typed),
    .out(outs[OUT_HYBRID])
);

// ------ Plain wiring ----------------------------
ready_valid_i #(type_t) plain_type(clk, reset_synced), plain_cast_type(clk, reset_synced);
ready_valid_i #(logic)  plain_required(clk, reset_synced); // is_required
ndata_i #(data8_t, DATABEAT_SIZE) plain_in(clk, reset_synced);
ndata_i #(data8_t, DATABEAT_SIZE) plain_stripped(clk, reset_synced), plain_out(clk, reset_synced);

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

    .conf(plain_required),

    .in(plain_in),
    .out(plain_stripped)
);

NDataSkidBuffer #(data8_t, DATABEAT_SIZE) inst_plain_stripped_skid_buffer  (
    .clk(clk),
    .rst_n(reset_synced),

    .in(plain_stripped),
    .out(plain_out)
);

typed_ndata_i #(DATABEAT_SIZE) plain_physical(clk, reset_synced);
NDataToTypedNData #(DATABEAT_SIZE) inst_plain_type (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(plain_type),
    .in(plain_out),

    .out(plain_physical)
);

// Narrows 64 bit values to INT32_T like the dictionary path, so both paths emit the same type into
// the TypedNormalizeUntil, which counts the values of a chunk in one type.
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_plain_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(plain_cast_type),

    .in(plain_physical),
    .out(outs[OUT_PLAIN])
);

// ------ Deferred dictionary decoding wiring -----
// With defer_dict_decoding, the chunk's output is the dictionary page's values followed by one
// index per value, as one byte stream. The dictionary page goes to the output as it is.
assign outs[OUT_DICT].data  = ins[IN_DICT_DEFERRED].data;
assign outs[OUT_DICT].typ   = BYTE_T;
assign outs[OUT_DICT].keep  = ins[IN_DICT_DEFERRED].keep;
assign outs[OUT_DICT].last  = ins[IN_DICT_DEFERRED].last;
assign outs[OUT_DICT].valid = ins[IN_DICT_DEFERRED].valid;
assign ins[IN_DICT_DEFERRED].ready = outs[OUT_DICT].ready;

// The HybridPageDecoder emits a single `last` per chunk, but the output multiplexer releases its
// select only at a `last`, and is selected per page. This ends every page's indices with a `last`.
ready_valid_i #(data32_t) ids_num_values(clk, reset_synced);
ndata_i #(id_t, NUM_IDS) ids_paged(clk, reset_synced);
DataRewriteLast #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_IDS)
) inst_ids_set_last (
    .clk(clk),
    .rst_n(reset_synced),

    .num_elements(ids_num_values),

    .in(ids_outs[IDS_OUTPUT]),
    .out(ids_paged)
);

// The RunDecoder ends a beat at every run, so the indices are packed densely for the cast.
ndata_i #(id_t, NUM_IDS) ids_normalized(clk, reset_synced);
DataNormalizer #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_IDS)
) inst_ids_normalizer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(ids_paged),
    .out(ids_normalized)
);

`ASSERT_ELAB(NUM_IDS * 4 == DATABEAT_SIZE)
typed_ndata_i #(DATABEAT_SIZE) ids_typed(clk, reset_synced), ids_narrowed(clk, reset_synced);
for (genvar I = 0; I < NUM_IDS; I++) begin
    assign ids_typed.data[4 * I +: 4] = data32_t'(ids_normalized.data[I]);
    assign ids_typed.keep[4 * I +: 4] = {4{ids_normalized.keep[I]}};
end
assign ids_typed.typ        = INT32_T;
assign ids_typed.last       = ids_normalized.last;
assign ids_typed.valid      = ids_normalized.valid;
assign ids_normalized.ready = ids_typed.ready;

ready_valid_i #(type_t) ids_type(clk, reset_synced);
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_ids_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(ids_type),

    .in(ids_typed),
    .out(ids_narrowed)
);

assign outs[OUT_IDS].data  = ids_narrowed.data;
assign outs[OUT_IDS].typ   = BYTE_T;
assign outs[OUT_IDS].keep  = ids_narrowed.keep;
assign outs[OUT_IDS].last  = ids_narrowed.last;
assign outs[OUT_IDS].valid = ids_narrowed.valid;
assign ids_narrowed.ready  = outs[OUT_IDS].ready;

// ------ Output multiplexing ----------------------------
typed_ndata_i #(DATABEAT_SIZE) inner_out(clk, reset_synced);
TypedNDataMultiplexer #(DATABEAT_SIZE, NUM_OUT) inst_demultiplexer (
    .clk(clk),
    .rst_n(reset_synced),

    .select(out_select),

    .in(outs),
    .out(inner_out)
);

ready_valid_i #(data32_t) num_values(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) normalized(clk, reset_synced);
TypedNormalizeUntil #(
    .size_t(data32_t), 
    .DATABEAT_SIZE(DATABEAT_SIZE),
    .BARREL_SHIFTER_REGISTER_LEVELS(2)
) inst_normalize_until_out (
    .clk(clk),
    .rst_n(reset_synced),

    .size(num_values),

    .in(inner_out),
    .out(normalized)
);

// Casts 32 bit values to the logical type (INT16_T or BYTE_T), also those the paths narrowed from
// 64 bit. Values already in the logical type pass through. It is placed after TypedNormalizeUntil,
// which provides the dense input the cast requires.
ready_valid_i #(type_t) logical_type(clk, reset_synced);
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_cast (
    .clk(clk),
    .rst_n(reset_synced),

    .out_type(logical_type),

    .in(normalized),
    .out(out)
);

// ------------------------------------------------
// ------ Design wiring ---------------------------
// ------------------------------------------------

// ------ Preserve+forward metadata ---------------
typedef enum logic [1:0] {
    ST_IDLE,
    ST_CONFIGURED,
    ST_PROCESS_PAGE
} state_t;
state_t state;

type_t typ;
type_t path_typ; // Type the dictionary and plain paths emit
logic is_required;
logic last_page;

logic    defer_dict_decoding;
data32_t chunk_num_values;
type_t   index_typ;

function automatic type_t index_type(data32_t num_entries);
    if (num_entries <= 256) begin
        return BYTE_T;
    end else if (num_entries <= 65536) begin
        return INT16_T;
    end
    return INT32_T;
endfunction

function automatic data32_t deferred_output_size(type_t typ, data32_t num_entries,
                                                  data32_t num_values);
    data32_t dictionary_bytes, index_bytes;
    dictionary_bytes = GET_TYPE_WIDTH(typ) == 64 ? num_entries << 3 : num_entries << 2;
    case (index_type(num_entries))
        BYTE_T:  index_bytes = num_values;
        INT16_T: index_bytes = num_values << 1;
        default: index_bytes = num_values << 2;
    endcase
    return dictionary_bytes + index_bytes;
endfunction

// Whether this chunk has had a dictionary page (and thus whether the dictionary path needs a last 
// data beat) for the TypedDictionary to reset it's internal state.
logic dict_seen;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        decompressor_conf.data  <= 'X;
        decompressor_conf.valid <= 1'b0;

        num_values.data  <= 'X;
        num_values.valid <= 1'b0;

        logical_type.data  <= 'X;
        logical_type.valid <= 1'b0;

        in_select.data  <= 'X;
        in_select.valid <= 1'b0;

        hybrid_conf.data  <= 'X;
        hybrid_conf.keep  <= 'X;
        hybrid_conf.last  <= 'X;
        hybrid_conf.valid <= 1'b0;

        hybrid_num_values.data  <= 'X;
        hybrid_num_values.valid <= 1'b0;

        out_select.data  <= 'X;
        out_select.valid <= 1'b0;

        dict_type.data  <= 'X;
        dict_type.valid <= 1'b0;

        dict_cast_type.data  <= 'X;
        dict_cast_type.valid <= 1'b0;

        plain_type.data  <= 'X;
        plain_type.valid <= 1'b0;

        plain_cast_type.data  <= 'X;
        plain_cast_type.valid <= 1'b0;

        plain_required.data  <= 'X;
        plain_required.valid <= 1'b0;

        ids_select.data  <= ids_selector_t'('X);
        ids_select.valid <= 1'b0;

        ids_type.data  <= 'X;
        ids_type.valid <= 1'b0;

        ids_num_values.data  <= 'X;
        ids_num_values.valid <= 1'b0;

        defer_dict_decoding <= 'X;
        chunk_num_values  <= 'X;
        index_typ         <= type_t'('X);

        typ         <= BYTE_T;
        path_typ    <= type_t'('X);
        is_required <= 'X;
        dict_seen   <= 'X;
        last_page   <= 'X;
        state       <= ST_IDLE;
    end else begin
        if (logical_type.ready) begin
            logical_type.valid <= 1'b0;
        end

        case (state)
            ST_IDLE: begin
                if (chunk_confs[0].valid && chunk_confs[0].ready) begin
                    decompressor_conf.data <= chunk_confs[0].data.compression;

                    // With defer_dict_decoding, the size is known with the dictionary page
                    num_values.data  <= chunk_confs[0].data.num_values;
                    num_values.valid <= !chunk_confs[0].data.defer_dict_decoding;

                    logical_type.data  <= chunk_confs[0].data.defer_dict_decoding ? BYTE_T :
                                          chunk_confs[0].data.logical_typ;
                    logical_type.valid <= 1'b1;

                    defer_dict_decoding <= chunk_confs[0].data.defer_dict_decoding;
                    chunk_num_values  <= chunk_confs[0].data.num_values;

                    typ         <= chunk_confs[0].data.typ;
                    // 64 bit values cast to a narrower integer type are narrowed to INT32_T on the paths
                    path_typ    <= chunk_confs[0].data.typ == INT64_T &&
                                   chunk_confs[0].data.logical_typ inside {INT32_T, INT16_T, BYTE_T} ?
                                   INT32_T : chunk_confs[0].data.typ;
                    is_required <= chunk_confs[0].data.is_required;
                    dict_seen   <= 1'b0;
                    state       <= ST_CONFIGURED;
                end
            end
            ST_CONFIGURED: begin
                if (page_conf.valid) begin
                    // Input is always consumed, thus always configured
                    in_select.valid <= 1'b1;

                    last_page <= page_conf.data.last;
                    state     <= ST_PROCESS_PAGE;

                    decompressor_conf.valid <= 1'b1;

                    // In each switch case we:
                    // 1. Route input from the decompressor
                    // 2. Configure the module that will transform/consume the input
                    // 3. Configure the output multiplexing any
                    case (page_conf.data.page_type)
                        PAGE_TYPE_HYBRID: begin
                            in_select.data <= IN_HYBRID;

                            hybrid_conf.data.num_values  <= page_conf.data.num_values;
                            hybrid_conf.data.is_required <= is_required;
                            hybrid_conf.keep             <= 1'b1;
                            hybrid_conf.last             <= page_conf.data.last;
                            hybrid_conf.valid            <= 1'b1;

                            if (defer_dict_decoding) begin
                                ids_num_values.data  <= page_conf.data.num_values;
                                ids_num_values.valid <= 1'b1;

                                ids_type.data  <= index_typ;
                                ids_type.valid <= 1'b1;

                                out_select.data  <= OUT_IDS;
                                out_select.valid <= 1'b1;
                            end else begin
                                hybrid_num_values.data  <= page_conf.data.num_values;
                                hybrid_num_values.valid <= 1'b1;

                                out_select.data  <= OUT_HYBRID;
                                out_select.valid <= 1'b1;
                            end
                        end
                        PAGE_TYPE_DICT: begin
                            if (defer_dict_decoding) begin
                                in_select.data <= IN_DICT_DEFERRED;

                                out_select.data  <= OUT_DICT;
                                out_select.valid <= 1'b1;

                                ids_select.data  <= IDS_OUTPUT;
                                ids_select.valid <= 1'b1;

                                index_typ <= index_type(page_conf.data.num_values);

                                num_values.data  <= deferred_output_size(
                                    typ, page_conf.data.num_values, chunk_num_values);
                                num_values.valid <= 1'b1;
                            end else begin
                                in_select.data <= IN_DICT;

                                dict_type.data  <= typ;
                                dict_type.valid <= 1'b1;

                                dict_cast_type.data  <= path_typ;
                                dict_cast_type.valid <= 1'b1;

                                ids_select.data  <= IDS_DICTIONARY;
                                ids_select.valid <= 1'b1;

                                dict_seen <= 1'b1;
                            end
                        end
                        PAGE_TYPE_PLAIN: begin
                            in_select.data <= IN_PLAIN;

                            plain_type.data  <= typ;
                            plain_type.valid <= 1'b1;

                            plain_cast_type.data  <= path_typ;
                            plain_cast_type.valid <= 1'b1;

                            plain_required.data  <= is_required;
                            plain_required.valid <= 1'b1;

                            out_select.data  <= OUT_PLAIN;
                            out_select.valid <= 1'b1;

                            if (page_conf.data.last && dict_seen) begin
                                // The chunk ends on a non-hybrid page but there was a 
                                // dictionary page. Inject a dummy reset beat (keep=0, last=1).
                                hybrid_conf.data  <= '0;
                                hybrid_conf.keep  <= 1'b0;
                                hybrid_conf.last  <= 1'b1;
                                hybrid_conf.valid <= 1'b1;
                            end
                        end
                    endcase
                end
            end
            ST_PROCESS_PAGE: begin
                if (decompressor_conf.ready) begin
                    decompressor_conf.valid <= 1'b0;
                end

                if (hybrid_conf.ready) begin
                    hybrid_conf.valid <= 1'b0;
                end

                if (dict_type.ready) begin
                    dict_type.valid <= 1'b0;
                end

                if (dict_cast_type.ready) begin
                    dict_cast_type.valid <= 1'b0;
                end

                if (plain_type.ready) begin
                    plain_type.valid <= 1'b0;
                end

                if (plain_cast_type.ready) begin
                    plain_cast_type.valid <= 1'b0;
                end

                if (plain_required.ready) begin
                    plain_required.valid <= 1'b0;
                end

                if (ids_select.ready) begin
                    ids_select.valid <= 1'b0;
                end

                if (ids_type.ready) begin
                    ids_type.valid <= 1'b0;
                end

                if (ids_num_values.ready) begin
                    ids_num_values.valid <= 1'b0;
                end

                if (in_select.ready) begin
                    in_select.valid <= 1'b0;
                end

                if (out_select.ready) begin
                    out_select.valid <= 1'b0;
                end

                if (hybrid_num_values.ready) begin
                    hybrid_num_values.valid <= 1'b0;
                end

                // If all configurations/selectors are invalid, it means they
                // have been successfully consumed by the multiplexers/decoders
                // (or not been set in the first place) and thus we can move
                // back to either state:
                // - IDLE if this was the last page, thus we're expecting
                //   a new column chunk configuration next.
                // - CONFIGURED if this was not the last page and this column
                //   chunk has more pages to be fully decoded.
                if (!decompressor_conf.valid && !hybrid_conf.valid && !dict_type.valid && !dict_cast_type.valid && !plain_type.valid && !plain_cast_type.valid && !plain_required.valid && !ids_select.valid && !ids_type.valid && !ids_num_values.valid && !in_select.valid && !out_select.valid) begin
                    if (last_page) begin
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_CONFIGURED;
                    end
                end
            end
        endcase

        // Only a handshake clears it, since a dictionary page sets it in ST_CONFIGURED
        if (state != ST_IDLE) begin
            if (num_values.valid && num_values.ready) begin
                num_values.valid <= 1'b0;
            end
        end
    end
end

// The cast takes the logical type once the previous chunk's last beat passed it. Holding back the
// next chunk until then keeps the pending logical type from being overwritten.
assign chunk_confs[0].ready = state == ST_IDLE && !logical_type.valid;
assign page_conf.ready      = state == ST_CONFIGURED;

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced)
    !(state == ST_CONFIGURED && page_conf.valid && defer_dict_decoding &&
      page_conf.data.page_type == PAGE_TYPE_PLAIN))
else $fatal(1, "ColumnChunkDecoder got a PLAIN data page in a defer_dict_decoding chunk");
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
