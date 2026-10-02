`timescale 1ns / 1ps

import lynxTypes::AXI_DATA_BITS;
import libstf::data8_t;
import libstf::data32_t;
import libstf::type_t;
import parcore::*;

module PageHeaderParser #(
    parameter NUM_BYTES = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s chunk_conf, // #(column_chunk_conf_t)

    ndata_i.s in,  // #(data8_t, NUM_BYTES) raw chunk
    ndata_i.m out, // #(data8_t, NUM_BYTES) payload

    ready_valid_i.m page_conf // #(page_conf_t)
);

`RESET_RESYNC

typedef enum logic [3:0] {
    IDLE,              // Wait for column chunk configuration
    PARSE_TYPE,
    SKIP_UNCOMP,
    PARSE_COMP,
    IS_CRC,
    PARSE_NVALS,
    PARSE_ENC,
    IS_END,
    SKIP_VARINT,
    SKIP_BINARY,
    PAYLOAD_FLUSH_BUF, // Emit one beat from buffer_data residue
    PAYLOAD_BYPASS,    // Steady-state: Route in.data to payload
    FLUSH_CONF
} state_t;

state_t state, n_state;
state_t next_state, n_next_state;

data8_t[NUM_BYTES + 3:0] buffer_data, n_buffer_data;
offset_t                 remaining_bytes, n_remaining_bytes;
data32_t                 skip_bytes, n_skip_bytes;
offset_t                 struct_depth, n_struct_depth;
data32_t                 remaining_chunk_num_values, n_remaining_chunk_num_values;

page_type_t parsed_page_type,    n_parsed_page_type;
data32_t    remaining_comp_size, n_remaining_comp_size;
data32_t    parsed_num_values,   n_parsed_num_values;

logic page_conf_valid, n_page_conf_valid;

data32_t                        cur_value;
logic[VARINT_LENGTH_BITS - 1:0] cur_length;

ndata_i #(data8_t, NUM_BYTES) payload(clk, reset_synced);

data8_t[NUM_BYTES-1:0] n_payload_data;
logic[NUM_BYTES-1:0]   n_payload_keep;
logic                  n_payload_last;
logic                  n_payload_valid;

// ---- VarintDecoder ------------------------------------------------------------------------------
valid_i #(data8_t[VARINT_NUM_BYTES - 1:0]) vdec_in(clk, reset_synced);
valid_i #(varint_t)                        vdec_out(clk, reset_synced);

assign vdec_in.data  = buffer_data[VARINT_NUM_BYTES - 1:0];
assign vdec_in.valid = 1'b1;

VarintDecoder inst_varint_decoder (
    .in(vdec_in),
    .out(vdec_out)
);

function automatic data32_t zigzag32(input logic [VARINT_NUM_BITS-1:0] n);
    return (data32_t'(n) >> 1) ^ {32{n[0]}};
endfunction


assign cur_value  = zigzag32(vdec_out.data.value);
assign cur_length = vdec_out.data.length;

// -- FSM ------------------------------------------------------------------------------------------
assign chunk_conf.ready = state == IDLE;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        state      <= IDLE;
        next_state <= IDLE;

        // Bytes that go into VarIntDecoder need to be assigned otherwise we get and assertion
        buffer_data                <= '0;
        remaining_bytes            <= 'X;
        skip_bytes                 <= 'X;
        struct_depth               <= 'X;
        remaining_chunk_num_values <= 'X;

        parsed_page_type    <= PAGE_TYPE_HYBRID;
        remaining_comp_size <= 'X;
        parsed_num_values   <= 'X;
        page_conf_valid     <= 1'b0;

        payload.data  <= 'X;
        payload.keep  <= 'X;
        payload.last  <= 'X;
        payload.valid <= 1'b0;
    end else begin
        state      <= n_state;
        next_state <= n_next_state;

        buffer_data                <= n_buffer_data;
        remaining_bytes            <= n_remaining_bytes;
        skip_bytes                 <= n_skip_bytes;
        struct_depth               <= n_struct_depth;
        remaining_chunk_num_values <= n_remaining_chunk_num_values;

        parsed_page_type    <= n_parsed_page_type;
        remaining_comp_size <= n_remaining_comp_size;
        parsed_num_values   <= n_parsed_num_values;
        page_conf_valid     <= n_page_conf_valid;

        payload.data  <= n_payload_data;
        payload.keep  <= n_payload_keep;
        payload.last  <= n_payload_last;
        payload.valid <= n_payload_valid;
    end
end

always_comb begin
    in.ready = 1'b0;

    // Hold payload register; clear valid when DataNormalizer accepts the beat.
    n_payload_data  = payload.data;
    n_payload_keep  = payload.keep;
    n_payload_last  = payload.last;
    n_payload_valid = payload.valid && !payload.ready;

    n_state      = state;
    n_next_state = next_state;

    n_buffer_data                = buffer_data;
    n_remaining_bytes            = remaining_bytes;
    n_skip_bytes                 = skip_bytes;
    n_struct_depth               = struct_depth;
    n_remaining_chunk_num_values = remaining_chunk_num_values;

    n_parsed_page_type    = parsed_page_type;
    n_remaining_comp_size = remaining_comp_size;
    n_parsed_num_values   = parsed_num_values;

    // Hold valid until accepted, then deassert
    n_page_conf_valid = page_conf_valid && !page_conf.ready;

    if (state != IDLE && state != PAYLOAD_FLUSH_BUF && state != PAYLOAD_BYPASS && state != FLUSH_CONF) begin
        if (remaining_bytes < 4) begin
            if (in.valid) begin
                // Append the input data beat behind the bytes already buffered. We clamp the 
                // remaining_bytes to two bits because it can be at max 3.
                n_buffer_data[remaining_bytes[1:0] +: NUM_BYTES] = in.data;
                n_remaining_bytes                                = remaining_bytes + $countones(in.keep);

                in.ready = 1'b1;
            end
        end else begin
            // We make progress one byte each cycle
            for (int i = 0; i < NUM_BYTES + 3; i++) begin
                n_buffer_data[i] = buffer_data[i + 1];
            end

            n_remaining_bytes = remaining_bytes - 1;

            if (skip_bytes != 0) begin
                n_skip_bytes = skip_bytes - 1;
            end
        end
    end

    case (state)
        IDLE: begin
            if (chunk_conf.valid) begin
                n_remaining_chunk_num_values = chunk_conf.data.num_values;
                n_remaining_bytes            = 0;
                // Tag byte of outer fid 1 is first byte of first beat so we always skip it
                n_skip_bytes                 = 1;
                n_state                      = PARSE_TYPE;
            end
        end
        PARSE_TYPE: begin
            if (skip_bytes == 0 && remaining_bytes > 3) begin
                // buffer_data[0] holds varint byte 0 of page_type; prefetch already consumed it.
                // DATA_PAGE=0, DICTIONARY_PAGE=2 (IndexPageHeader and DataPageHeaderV2 are currently not supported)
                n_parsed_page_type = (cur_value == 32'd2) ? PAGE_TYPE_DICT : PAGE_TYPE_HYBRID;
                // Skip remaining varint bytes (cur_length-1) + 1 tag byte to land on next varint byte 0
                n_skip_bytes = cur_length;
                n_state      = SKIP_UNCOMP;
            end
        end
        SKIP_UNCOMP: begin
            // Discard uncompressed size
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                n_skip_bytes = cur_length;
                n_state      = PARSE_COMP;
            end
        end
        PARSE_COMP: begin
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                n_remaining_comp_size = cur_value;
                // Skip remaining varint bytes only; IS_CRC reads the next tag byte directly
                n_skip_bytes          = cur_length - 1;
                n_state               = IS_CRC;
            end
        end
        IS_CRC: begin
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                if (buffer_data[0] == 8'h15) begin // Skip CRC
                    n_next_state = IS_CRC;
                    n_state      = SKIP_VARINT;
                end else begin // Start of struct
                    n_skip_bytes = 1;
                    n_state      = PARSE_NVALS;
                end
            end
        end
        PARSE_NVALS: begin
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                n_parsed_num_values = cur_value;
                // Skip remaining varint bytes + encoding tag byte to land on encoding varint byte 0
                n_skip_bytes        = cur_length;
                n_state             = PARSE_ENC;
            end
        end
        PARSE_ENC: begin
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                if (parsed_page_type != PAGE_TYPE_DICT) begin
                    // PLAIN=0, PLAIN_DICTIONARY=2, RLE_DICTIONARY=8 (Other encodings not supported
                    // yet). For data pages we already use PAGE_TYPE_HYBRID as a default so only 
                    // change for plain data pages.
                    if (cur_value == 32'd0) begin
                        n_parsed_page_type = PAGE_TYPE_PLAIN;
                    end

                    // Decrement only for data pages (hybrid and plain), not dict pages
                    n_remaining_chunk_num_values = remaining_chunk_num_values - parsed_num_values;
                end

                // Skip remaining varint bytes; IS_END starts on first tag byte of the inner struct
                n_skip_bytes   = cur_length - 1;
                n_struct_depth = 2;
                n_state        = IS_END;
            end
        end
        IS_END: begin
            if (skip_bytes == 0 && remaining_bytes != 3) begin
                if (buffer_data[0][3:0] == 4'h1 || buffer_data[0][3:0] == 4'h2) begin // bool
                    // Do nothing
                end else if (buffer_data[0][3:0] == 4'h4 || buffer_data[0][3:0] == 4'h5 ||
                             buffer_data[0][3:0] == 4'h6) begin // i16, i32, i64 varint
                    n_next_state = IS_END;
                    n_state      = SKIP_VARINT;
                end else if (buffer_data[0][3:0] == 4'h8) begin // binary
                    n_state = SKIP_BINARY;
                end else if (buffer_data[0][3:0] == 4'hC) begin // struct begin
                    n_struct_depth = struct_depth + 1;
                end else if (buffer_data[0] == 8'h00) begin // struct end
                    n_struct_depth = struct_depth - 1;

                    if (struct_depth == 1) begin
                        n_state           = PAYLOAD_FLUSH_BUF;
                        n_page_conf_valid = 1'b1;
                    end
                end
            end
        end
        SKIP_VARINT: begin
            // Only leave once the last varint byte is actually consumed, not in a refill cycle
            if (remaining_bytes != 3 && !buffer_data[0][7]) begin
                n_state = next_state;
            end
        end
        SKIP_BINARY: begin
            if (remaining_bytes != 3) begin
                // Binary length is an unsigned varint per Thrift compact spec, not zigzag.
                // Subtract 1 because we already consume the first byte in this clock cycle.
                n_skip_bytes = data32_t'(vdec_out.data.value) + cur_length - 1;
                n_state = IS_END;
            end
        end
        PAYLOAD_FLUSH_BUF: begin
            if (remaining_bytes == 0) begin
                // Buffer drained already.
                n_state = PAYLOAD_BYPASS;
            end else if (!payload.valid || payload.ready) begin
                n_payload_data  = buffer_data[NUM_BYTES - 1:0];
                n_payload_last  = (remaining_comp_size <= data32_t'(remaining_bytes));
                n_payload_valid = 1'b1;

                if (remaining_bytes > NUM_BYTES && remaining_comp_size > NUM_BYTES) begin
                    // Overflow: Buffer holds more than one full beat of payload. Emit
                    // buffer_data[NUM_BYTES-1:0] this cycle, shift remainder down, and stay in
                    // PAYLOAD_FLUSH_BUF for the next beat.
                    n_payload_keep = '1;

                    n_buffer_data[1:0] = buffer_data[NUM_BYTES+:2];

                    n_remaining_bytes     = remaining_bytes     - NUM_BYTES;
                    n_remaining_comp_size = remaining_comp_size - NUM_BYTES;
                end else if (remaining_comp_size < data32_t'(remaining_bytes)) begin
                    // Buffer also holds next page's bytes (incl. fid1 tag). Go directly to
                    // PARSE_TYPE with skip_bytes set to drain the stale payload bytes + fid1.
                    // Mask off bytes beyond the page boundary.
                    n_payload_keep = (remaining_comp_size == NUM_BYTES) ? '1 : ((NUM_BYTES)'(1) << remaining_comp_size) - 1;

                    n_remaining_comp_size = 0;
                    n_skip_bytes          = remaining_comp_size + 32'd1;

                    n_state = FLUSH_CONF;
                end else begin
                    // Whole buffer goes out this cycle (or exactly matches comp_size). Rest comes 
                    // from `in` via PAYLOAD_BYPASS.
                    n_payload_keep = (remaining_bytes == NUM_BYTES) ? '1 : ((NUM_BYTES)'(1) << remaining_bytes) - 1;

                    n_remaining_bytes     = '0;
                    n_remaining_comp_size = remaining_comp_size - remaining_bytes;
                    n_skip_bytes          = 1; // Need to skip the first byte of the following header

                    if (remaining_comp_size == remaining_bytes) begin
                        n_state = FLUSH_CONF;
                    end else begin
                        n_state = PAYLOAD_BYPASS;
                    end
                end
            end
        end
        PAYLOAD_BYPASS: begin
            if (!payload.valid || payload.ready) begin
                n_payload_data  = in.data;
                n_payload_last  = remaining_comp_size <= NUM_BYTES;

                if (remaining_comp_size > 0) begin
                    in.ready = 1'b1;

                    n_payload_valid = in.valid;

                    if (in.valid) begin
                        if (remaining_comp_size < NUM_BYTES) begin
                            // Last beat for this page. Mask off any bytes that lie beyond
                            // remaining_comp_size (they belong to a following page header).
                            n_payload_keep        = ((NUM_BYTES)'(1) << remaining_comp_size) - 1;
                            n_remaining_comp_size = 0;

                            // The bytes after remaining_comp_size in this beat belong to
                            // the next page header. Capture them into the buffer now
                            // (skipping the fid1 tag at position remaining_comp_size).
                            n_buffer_data[NUM_BYTES - 1:0] = in.data[NUM_BYTES - 1:0];
                            n_remaining_bytes              = $countones(in.keep);
                            n_skip_bytes                   = remaining_comp_size + 1;

                            n_state = FLUSH_CONF;
                        end else begin
                            n_payload_keep        = '1;
                            n_remaining_comp_size = remaining_comp_size - NUM_BYTES;

                            if (remaining_comp_size == NUM_BYTES) begin
                                n_state = FLUSH_CONF;
                            end
                        end
                    end
                end
            end
        end
        FLUSH_CONF: begin
            if (!n_page_conf_valid) begin
                if (remaining_chunk_num_values == 0) begin
                    n_state = IDLE;
                end else begin
                    n_state = PARSE_TYPE;
                end
            end
        end
    endcase
end

ndata_i #(data8_t, NUM_BYTES) normalizer_out(clk, reset_synced);

// Payload beats are emitted with left-aligned `keep`, so a barrel-shifter-only normalizer (no 
// compactor) is sufficient.
DataNormalizer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_BYTES),
    .ENABLE_COMPACTOR(0)
) inst_normalizer (
    .clk(clk), 
    .rst_n(reset_synced),
    
    .in(payload), 
    .out(normalizer_out)
);

NDataSkidBuffer #(data8_t, NUM_BYTES) inst_skid_out (
    .clk(clk), 
    .rst_n(reset_synced),

    .in(normalizer_out), 
    .out(out)
);

// ---- page_conf output ---------------------------------------------------------------------------
assign page_conf.data.page_type  = parsed_page_type;
assign page_conf.data.num_values = parsed_num_values;
assign page_conf.data.last       = remaining_chunk_num_values == 0;
assign page_conf.valid           = page_conf_valid;

endmodule
