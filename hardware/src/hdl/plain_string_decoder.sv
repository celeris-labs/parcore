`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "lynx_macros.svh"

import lynxTypes::*;
import parcore::*;

module PlainStringDecoder #(
    parameter int STREAM_WIDTH = AXI_DATA_BITS / 8
) (
    input  logic clk,
    input  logic rst_n,

    ready_valid_i.s conf,           // #(plain_str_decoder_conf_t)
    ndata_i.s       in_data,        // #(data8_t, STREAM_WIDTH)
    data_i.m        out_strings,    // #(german_str_t)
    ndata_i.m       out_data        // #(data8_t, STREAM_WIDTH)
);

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------
    localparam int LENGTH_PREFIX_LEN    = 4;
    localparam int STR_PREFIX_LEN       = 4;
    localparam int INLINE_STR_BYTES     = 12;
    localparam int VIEW_EXTENSION_WIDTH = LENGTH_PREFIX_LEN + INLINE_STR_BYTES - 1;
    localparam int VIEW_WIDTH           = STREAM_WIDTH + VIEW_EXTENSION_WIDTH;
    localparam int VIEW_BITS            = $clog2(STREAM_WIDTH);

    // ---------------------------------------------------------------------
    // Input side prelude
    // Build lookahead beats + skid
    // ---------------------------------------------------------------------
    ndata_i #(data8_t, VIEW_WIDTH) in_extended (.*);
    ndata_i #(data8_t, VIEW_WIDTH) in (.*);
    Lookahead #(
        .data_t       (data8_t),
        .NUM_ELEMENTS (STREAM_WIDTH),
        .PREVIEW_SIZE (VIEW_EXTENSION_WIDTH)
    ) in_extender (
        .clk    ( clk ),
        .rst_n  ( rst_n ),

        .in     ( in_data ),
        .out    ( in_extended )
    );

    NDataSkidBuffer #(
        .data_t(data8_t),
        .NUM_ELEMENTS(VIEW_WIDTH)
    ) in_skidder (
        .clk    ( clk ),
        .rst_n  ( rst_n ),

        .in     ( in_extended ),
        .out    ( in )
    );

    // ---------------------------------------------------------------------
    // Output side postlude
    // Skidding
    // ---------------------------------------------------------------------
    ndata_i #(data8_t, STREAM_WIDTH) out_data_internal (.*);
    NDataSkidBuffer #(
        .data_t(data8_t),
        .NUM_ELEMENTS(STREAM_WIDTH)
    ) raw_out_skidder (
        .clk    ( clk ),
        .rst_n  ( rst_n ),

        .in     ( out_data_internal ),
        .out    ( out_data )
    );

    data_i #(german_str_t) out_strings_internal (.*);
    DataSkidBuffer #(
        .data_t(german_str_t)
    ) string_out_skidder (
        .clk    ( clk ),
        .rst_n  ( rst_n ),

        .in     ( out_strings_internal ),
        .out    ( out_strings )
    );


    // ---------------------------------------------------------------------
    // Input side buffering
    // ---------------------------------------------------------------------
    ndata_i#(data8_t, VIEW_WIDTH) in_data_buffer (.clk(clk), .rst_n(rst_n));
    assign in_data_buffer.ready = 1;
    assign in_data_buffer.valid = 0;

    // ---------------------------------------------------------------------
    // Offset / length bookkeeping
    // ---------------------------------------------------------------------
    data32_t                    values_remaining;
    data32_t                    cursor;
    data32_t                    cursor_after_prefix;
    logic[VIEW_BITS - 1 : 0]    view_cursor;
    data32_t                    length;
    data32_t                    cursor_n;

    assign view_cursor = cursor[VIEW_BITS-1:0];

    always_comb begin : extract_length
        length = '0;
        for (int i = 0; i < LENGTH_PREFIX_LEN; i++)
            length[i*8 +: 8] = in_data_buffer.data[view_cursor + i];
    end


    assign cursor_n = cursor + LENGTH_PREFIX_LEN + length;

    // ---------------------------------------------------------------------
    // Control signals
    // ---------------------------------------------------------------------
    logic cursor_in_view;
    logic cursor_n_crosses;
    logic last_val;
    logic is_short;
    logic bytes_left_in_next_beat;

    assign cursor_in_view = cursor < STREAM_WIDTH;
    assign cursor_n_crosses = cursor_n > STREAM_WIDTH;
    assign last_val = values_remaining == 1;
    assign is_short = length <= INLINE_STR_BYTES;
    assign bytes_left_in_next_beat = cursor > STREAM_WIDTH;

    // ---------------------------------------------------------------------
    // German String Construction
    // ---------------------------------------------------------------------
    logic [63:0]                    heap_addr;
    german_str_t                    german;
    data8_t [INLINE_STR_BYTES:0]    str_bytes;

    always_comb begin : buildStr
        for (int i = 0; i < INLINE_STR_BYTES; i++)
            str_bytes[i] = i < length ? in_data_buffer.data[view_cursor + i + LENGTH_PREFIX_LEN] : '0;
    end

    always_comb begin : build_german
        german        = '0;
        german.length = length;
        for (int i = 0; i < STR_PREFIX_LEN; i++)
            german.prefix[i] = str_bytes[i];
        for (int i = 0; i < 8; i++)
            german.short_str_or_addr[i] = is_short ?
                str_bytes[i + STR_PREFIX_LEN] :
                heap_addr[i*8 +: 8];
    end

    task updateInputBuffer();
        in_data_buffer.data <= in.data;
        in_data_buffer.keep <= in.keep;
        in_data_buffer.last <= in.last;
    endtask

    // ---------------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------------
    typedef enum logic[1:0] { WAIT_CONF, WAIT_FIRST, EMIT_LENS_AND_STREAM, EMIT_STREAM } state_t;
    state_t state;

    always_ff @( posedge clk ) begin : length_extractor_fsm
    if ( !rst_n ) begin
        state <= WAIT_CONF;
        cursor <= 0;
        values_remaining <= 0;
        in_data_buffer.data <= '0;
        in_data_buffer.keep <= '0;
        in_data_buffer.last <= 0;
    end else begin
        case (state)
            WAIT_CONF: begin
                if (conf.valid) begin
                    if (in.valid)
                        state <= EMIT_LENS_AND_STREAM;
                    else
                        state <= WAIT_FIRST;
                    cursor <= 0;
                    values_remaining <= conf.data.num_values;
                    if (conf.data.update_buffer_addr)
                        heap_addr <= conf.data.buffer_addr + LENGTH_PREFIX_LEN;
                    cursor_after_prefix <= LENGTH_PREFIX_LEN;
                    updateInputBuffer();
                end
            end
            WAIT_FIRST: begin
                if (in.valid)
                    state <= EMIT_LENS_AND_STREAM;
                updateInputBuffer();
            end
            EMIT_LENS_AND_STREAM: begin
                // Cursor update logic
                if (!cursor_in_view) begin
                    if(out_data_internal.ready && in.valid) begin
                        cursor <= cursor - STREAM_WIDTH;
                    end
                end else if (out_strings_internal.ready) begin
                    if (cursor_n_crosses && out_data_internal.ready && in.valid) begin
                        cursor <= cursor_n - STREAM_WIDTH;
                        heap_addr <= heap_addr + LENGTH_PREFIX_LEN + length;
                    end
                    else if (!cursor_n_crosses && (!last_val || out_data_internal.ready)) begin
                        cursor <= cursor_n;
                        heap_addr <= heap_addr + LENGTH_PREFIX_LEN + length;
                    end
                end

                // Values are only updated when lengths are emitted
                if(out_strings_internal.valid && out_strings_internal.ready)
                    values_remaining <= values_remaining - 1;
                
                // Input buffer update logic
                if ((!cursor_in_view || (cursor_n_crosses && out_strings_internal.ready)) && out_data_internal.ready && in.valid) begin
                    updateInputBuffer();
                end

                // state update logic
                if (cursor_in_view && last_val && out_strings_internal.ready && out_data_internal.ready) begin
                    if (!cursor_n_crosses)
                        state <= WAIT_CONF;
                    else if (in.valid)
                        state <= EMIT_STREAM;
                end
            end
            EMIT_STREAM: begin
                if (out_data_internal.ready && (in.valid || !bytes_left_in_next_beat)) begin
                    cursor <= cursor - STREAM_WIDTH;
                    updateInputBuffer();
                end

                if (!bytes_left_in_next_beat && out_data_internal.ready)
                    state <= WAIT_CONF; 
            end
            default: begin
                
            end
        endcase
    end
    end

    always_comb begin
        case (state)
            WAIT_CONF: in.ready = 1;
            WAIT_FIRST: in.ready = 1;
            EMIT_LENS_AND_STREAM: in.ready = out_data_internal.ready &&
                    (!cursor_in_view || (cursor_n_crosses && out_strings_internal.ready));
            EMIT_STREAM: in.ready = bytes_left_in_next_beat && out_data_internal.ready;
        endcase
    end

    assign conf.ready = state == WAIT_CONF;
    assign out_strings_internal.valid =
            state == EMIT_LENS_AND_STREAM &&
            cursor_in_view &&
            (
                (cursor_n_crosses && out_data_internal.ready && in.valid) ||
                (!cursor_n_crosses && (!last_val || out_data_internal.ready))
            );
    assign out_strings_internal.data = german;
    assign out_strings_internal.keep = 1;
    assign out_strings_internal.last = last_val;
    assign out_data_internal.valid =
            state == EMIT_LENS_AND_STREAM &&
            (
                (!cursor_in_view && in.valid) ||
                (cursor_in_view && out_strings_internal.ready && ((cursor_n_crosses && in.valid) || (!cursor_n_crosses && last_val)))
            ) ||
            (state == EMIT_STREAM && (in.valid || !bytes_left_in_next_beat));
    assign out_data_internal.data = in_data_buffer.data;
    assign out_data_internal.keep = in_data_buffer.keep;
    assign out_data_internal.last = in_data_buffer.last;

endmodule
