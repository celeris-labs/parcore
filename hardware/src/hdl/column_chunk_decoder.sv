`timescale 1ns / 1ps

`include "libstf_macros.svh"

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import libstf::BYTE_T;
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
localparam int NUM_IN = 3;
typedef enum logic [$bits(page_type_t) - 1:0] {
    IN_HYBRID = PAGE_TYPE_HYBRID,
    IN_DICT = PAGE_TYPE_DICT,
    IN_PLAIN = PAGE_TYPE_PLAIN
} in_selector_t;
`ASSERT_ELAB(NUM_IN <= 2**$bits(in_selector_t))

ndata_i #(data8_t, DATABEAT_SIZE) ins[NUM_IN](clk, reset_synced);

localparam int NUM_OUT = 2;
typedef enum logic {
  OUT_HYBRID = 0,
  OUT_PLAIN = 1
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

ndata_i #(id_t, NUM_IDS) dict_ids(clk, reset_synced);
HybridPageDecoder #(
    .data_t(id_t),
    .NUM_ELEMENTS(NUM_IDS),
    .NUM_BYTES(DATABEAT_SIZE)
) inst_hybrid_page_decoder (
    .clk(clk),
    .rst_n(reset_synced),

    .conf(hybrid_conf),
    .in(ins[IN_HYBRID]),

    .out(dict_ids)
);

ready_valid_i #(type_t) dict_type(clk, reset_synced);
typed_ndata_i #(DATABEAT_SIZE) dict_values(clk, reset_synced);
NDataToTypedNData #(DATABEAT_SIZE) inst_dict_typed_conversion (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(dict_type),
    .in(ins[IN_DICT]),

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
    .in_ids(dict_ids),

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
ready_valid_i #(type_t) plain_type(clk, reset_synced);
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

NDataToTypedNData #(DATABEAT_SIZE) inst_plain_type (
    .clk(clk),
    .rst_n(reset_synced),

    .in_type(plain_type),
    .in(plain_out),

    .out(outs[OUT_PLAIN])
);

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
TypedNormalizeUntil #(
    .size_t(data32_t), 
    .DATABEAT_SIZE(DATABEAT_SIZE),
    .BARREL_SHIFTER_REGISTER_LEVELS(2)
) inst_normalize_until_out (
    .clk(clk),
    .rst_n(reset_synced),

    .size(num_values),

    .in(inner_out),
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
logic is_required;
logic last_page;

// Whether this chunk has had a dictionary page (and thus whether the dictionary path needs a last 
// data beat) for the TypedDictionary to reset it's internal state.
logic dict_seen;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        decompressor_conf.valid <= 1'b0;
        num_values.valid        <= 1'b0;
        hybrid_num_values.valid <= 1'b0;

        hybrid_conf.valid    <= 1'b0;
        dict_type.valid      <= 1'b0;
        plain_type.valid     <= 1'b0;
        plain_required.valid <= 1'b0;
        in_select.valid      <= 1'b0;
        out_select.valid     <= 1'b0;

        typ         <= BYTE_T;
        is_required <= 'X;
        last_page   <= 'X;
        state       <= ST_IDLE;
    end else begin
        case (state)
            ST_IDLE: begin
                if (chunk_confs[0].valid && chunk_confs[0].ready) begin
                    decompressor_conf.data <= chunk_confs[0].data.compression;

                    num_values.data  <= chunk_confs[0].data.num_values;
                    num_values.valid <= 1'b1;

                    typ         <= chunk_confs[0].data.typ;
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

                            hybrid_num_values.data  <= page_conf.data.num_values;
                            hybrid_num_values.valid <= 1'b1;

                            out_select.data  <= OUT_HYBRID;
                            out_select.valid <= 1'b1;
                        end
                        PAGE_TYPE_DICT: begin
                            in_select.data <= IN_DICT;

                            dict_type.data  <= typ;
                            dict_type.valid <= 1'b1;

                            dict_seen <= 1'b1;
                        end
                        PAGE_TYPE_PLAIN: begin
                            in_select.data <= IN_PLAIN;

                            plain_type.data  <= typ;
                            plain_type.valid <= 1'b1;

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

                if (plain_type.ready) begin
                    plain_type.valid <= 1'b0;
                end

                if (plain_required.ready) begin
                    plain_required.valid <= 1'b0;
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
                if (!decompressor_conf.valid && !hybrid_conf.valid && !dict_type.valid && !plain_type.valid && !plain_required.valid && !in_select.valid && !out_select.valid) begin
                    if (last_page) begin
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_CONFIGURED;
                    end
                end
            end
        endcase

        if (state != ST_IDLE) begin
            if (num_values.ready) begin
                num_values.valid <= 1'b0;
            end
        end
    end
end

assign chunk_confs[0].ready = state == ST_IDLE;
assign page_conf.ready      = state == ST_CONFIGURED;

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
