`timescale 1ns / 1ps

`include "libstf_macros.svh"
`include "lynx_macros.svh"

import lynxTypes::*;
import libstf::*;
import parcore::*;

module RunDecoder #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter NUM_BYTES = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // #(run_decoder_config_t)
    ndata_i.s in,         // #(data8_t, NUM_BYTES)

    ndata_i.m out         // #(data_t, NUM_ELEMENTS)
);

`RESET_RESYNC // Reset pipelining

// This is a simplification made to have better timing closure. Under this
// assumption, all bitpacking encodings are bit_width * NUM_ELEMENTS bits
// long. Because NUM_ELEMENTS is divisible by 8, then so is the number of bits
// of each BPE run. Thanks to that, there is never any bit-level offset
// between BPE sections, and we can thus avoid keeping track of that,
// simplifying indexing and avoiding some divisions (which would in turn
// require DSPs on the critical path).
`ASSERT_ELAB(NUM_ELEMENTS % 8 == 0);

localparam int MAX_IN_TRANSIT = 8;
localparam int DATA_SIZE = ($bits(data_t) + 7) / 8;
localparam int VARINT_OFFSET_COMPUTATION_WIDTH = 18;

// Positions of the next header relative to the not yet shifted buffer can lie beyond its end, so
// they need one more bit than offset_t.
typedef logic [$bits(offset_t):0] header_offset_t;

// ------- Input extraction ------
data8_t[NUM_BYTES - 1:0] in_data;
assign in_data = in.data;
logic[NUM_BYTES - 1:0] in_keep;
assign in_keep = in.keep;

run_decoder_config_t conf_data;
assign conf_data = conf.data;

// ------- State declaration -----

typedef enum logic [2:0] {
    ST_IDLE,
    ST_HEADER,
    ST_HEADER2,
    ST_DECODE_RLE,
    ST_DECODE_BPE
} state_t;
state_t state;

logic store_in_second_half;
data8_t[NUM_BYTES * 2 - 1:0] data;
logic[NUM_BYTES * 2 - 1:0] keep;
logic last_received;
bit_width_t bit_width;
logic [BPE_MASK_SIZE - 1:0] bit_width_bpe_mask;
offset_t offset;
data32_t remaining_values;

// ------- Combinatorial state ---
data8_t[NUM_BYTES * 2 - 1:0] next_data;
logic[NUM_BYTES * 2 - 1:0] next_keep;
logic next_last_received;

// n bits for bit_width_t, + log2(NUM_ELEMENTS) bits
// as this value is the result of bit_width * NUM_ELEMENTS;
logic[$clog2(NUM_ELEMENTS) + $bits(bit_width_t) - 1:0] packed_databeat_bits;
logic[$clog2(NUM_ELEMENTS) + $bits(bit_width_t) - 1 - $clog2(8):0] packed_databeat_bytes;
logic[$clog2(8) + $bits(bit_width_t) - 1 - $clog2(8):0] eight_packed_databeat_bytes;
offset_t varint_offset;

// ------- Output declaration -----
typedef enum logic {
  OUTPUT_RLE,
  OUTPUT_BPE
} output_t;
valid_i #(output_t) next_out(clk, reset_synced), curr_out(clk, reset_synced);
// This signal is used to apply backpressure from the output queue. In case
// the queue gets full, this signal will be low and the next decoding will be
// paused until there's space in the queue to store it.
logic can_decode_next;

always_comb begin
    // Default assignments prevent latch inference on next_out.data.
    next_out.data  = OUTPUT_RLE;
    next_out.valid = 1'b0;

    case (state)
        ST_DECODE_RLE: begin
            next_out.data = OUTPUT_RLE;
            next_out.valid = rle_in.valid && rle_in.ready;
        end

        ST_DECODE_BPE: begin
            next_out.data = OUTPUT_BPE;
            next_out.valid = bpe_in.valid && bpe_in.ready;
        end
    endcase
end

// ------- State declaration (decoders) -----
logic [3:0] rle_width;
rle_count_t rle_count;

// Assuming worse case: 0...2**$bits(data_t)-1 repeated twice.
// In that case, each elements takes ceil($bits(data_t)/8) bytes to be
// encoded. Subtract by log2(NUM_ELEMNETS) for number of BPE inputs.
localparam int ENC_BYTES   = ($bits(data_t) + 7) / 8;          // ceil($bits/8)
localparam int BASE_BITS   = ($bits(data_t) - 1) + ENC_BYTES;  // worst-case size

typedef logic [BASE_BITS - $clog2(NUM_ELEMENTS) - 1:0] bpe_remaining_inputs_t;

// The value in bpe_count is computed by << 3 the value in the header
// (ignoring the LSB). This means that it'll be a multiple of 8.
// For runs where the number of values encoded in BPE is not a multiple of 8,
// the bpe_count is lower-bounded by the total number of values in the page,
// which is found in conf_data.num_values.
bpe_count_t bpe_count;
bpe_remaining_inputs_t bpe_remaining_inputs; 


// ------- Combinatorial state (decoders) ---
// This is a bit-level view of the data
logic [NUM_BYTES * 8 * 2 - 1:0] bpe_data;
generate
for (genvar i = 0; i < NUM_BYTES * 2; i++) begin
    assign bpe_data[(i+1) * 8 - 1:i * 8] = data[i];
end
endgenerate

// ------- Header varint decoding

// To have some valid varint input, we must either have:
// - up to 4 valid bytes
// - at least 1 valid byte if we've received last. We assume the input is
// correct.
valid_i #(data8_t[VARINT_NUM_BYTES - 1:0]) varint_in(clk, reset_synced);
valid_i #(varint_t) varint_out(clk, reset_synced);

VarintDecoder inst_varint_decoder (
    .in(varint_in),
    .out(varint_out)
);

// While decoding BPE, varint_offset is stored trimmed (mod NUM_BYTES) even if
// the run ends in the second buffer half and the buffer has not been shifted
// yet. The next header is always less than NUM_BYTES ahead of offset, so a
// varint_offset that isn't ahead of offset lies in the second half.
offset_t current_varint_offset;
assign current_varint_offset = (state == ST_DECODE_BPE && varint_offset <= offset)
                               ? varint_offset + NUM_BYTES : varint_offset;

data8_t[3:0] expected_varint_data;
assign expected_varint_data = data[current_varint_offset +: 4];

// The right side of ==? must be a constant in Verilator. It is two-state and
// both sides read the same buffer, so == is enough there.
`ifdef VERILATOR
assert property (@(posedge clk) disable iff (!rst_n) !varint_in.valid || (expected_varint_data == varint_in.data))
`else
assert property (@(posedge clk) disable iff (!rst_n) !varint_in.valid || (expected_varint_data ==? varint_in.data))
`endif
else $fatal(1, "Varint input data does not match the data at the current offset. In state %d, at varint_offset 0x%x, offset 0x%x, expected 0b%b (%x), got 0b%b (%x)", state, current_varint_offset, offset, expected_varint_data, expected_varint_data, varint_in.data, varint_in.data);

// Combinatorial shift values from the varint value used to compute rle_count
// and bpe_count.
logic varint_encoding;
assign varint_encoding = varint_out.data.value[0];
typedef enum logic {
    ENCODING_RLE = 0,
    ENCODING_BPE = 1
} varint_encoding_t;
rle_count_t varint_no_encoding;
assign varint_no_encoding = varint_out.data.value >> 1;
bpe_count_t varint_no_encoding_bytes;
assign varint_no_encoding_bytes = varint_no_encoding  << 3;

// ------- RLE decoding
tagged_i #(data_t, rle_count_t) rle_in(clk, reset_synced);
ndata_i #(data_t, NUM_ELEMENTS) rle_out(clk, reset_synced);

ExpandRLE #(
    .data_t(data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_expand_rle (
    .clk(clk),
    .rst_n(reset_synced),

    .in(rle_in),
    .out(rle_out)
);

assign rle_in.tag = rle_count;
logic[DATA_SIZE - 1:0] rle_in_valid_bits;
logic[DATA_SIZE - 1:0] rle_needs_to_buffer_bits;
generate
for (genvar i = 0; i < DATA_SIZE; i++) begin
    // We need to copy bit-by-bit here as for value sizes that are not
    // multiple of eight, DATA_SIZE will be an over approximation of how many
    // bytes are required. For example, for $bits(data_t) = 18, DATA_SIZE = 3,
    // but we can't access indexes 23:18, only 17:16 for the last byte.
    for (genvar b = 0; b < 8 && i * 8 + b < $bits(data_t); b++) begin
        assign rle_in.data[i * 8 + b] = (i < rle_width) ? data[offset+i][b] : '0;
    end
    assign rle_in_valid_bits[i] = (i >= rle_width) || keep[offset+i];
    assign rle_needs_to_buffer_bits[i] = (i < rle_width && ~keep[offset+i]);
end
endgenerate
assign rle_in.valid = can_decode_next &&state == ST_DECODE_RLE && &rle_in_valid_bits;
logic rle_needs_more_input;
assign rle_needs_more_input = |rle_needs_to_buffer_bits && ~last_received;

// ------- BPE decoding
bpe_config_t bpe_in_tag;
assign bpe_in_tag.bit_width = bit_width;
assign bpe_in_tag.mask = bit_width_bpe_mask;
assign bpe_in_tag.count = bpe_count;

tagged_i #(logic [$bits(data_t) * NUM_ELEMENTS - 1:0], bpe_config_t) bpe_in(clk, reset_synced);
ndata_i  #(data_t, NUM_ELEMENTS) bpe_out(clk, reset_synced);

ExpandBPE #(
    .data_t(data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .MAX_IN_TRANSIT(MAX_IN_TRANSIT)
) inst_expand_bpe (
    .clk(clk),
    .rst_n(reset_synced),

    .in(bpe_in),
    .out(bpe_out)
);

// NOTE: ExpandBPE doesn't look at the keep signals.
assign bpe_in.data = bpe_data[offset * 8 +: $bits(data_t) * NUM_ELEMENTS];
assign bpe_in.last = bpe_count <= NUM_ELEMENTS;
assign bpe_in.tag = bpe_in_tag;
// OPTIMIZATION: here we're only checking for the first and last bit of the
// desired keep region, to avoid a wide & over several bits.
logic bpe_valid_bytes, bpe_valid_bytes_lo, bpe_valid_bytes_hi;
assign bpe_valid_bytes_lo = keep[offset];
assign bpe_valid_bytes_hi = keep[offset + packed_databeat_bytes - 1];
assign bpe_valid_bytes = bpe_valid_bytes_lo && bpe_valid_bytes_hi;

assign bpe_in.valid = can_decode_next && state == ST_DECODE_BPE && (bpe_valid_bytes || last_received) && bpe_count > 0;

// We want to take more input if some of the keep bytes are not high, and
// only if we haven't already consumed the last databeat.
logic bpe_needs_more_input;
assign bpe_needs_more_input = ~bpe_valid_bytes && ~last_received;


// ------- Combinatorial input ---
always_comb begin
    next_data = data;
    next_keep = keep;

    if (in.valid) begin
        if (store_in_second_half) begin
            next_data[NUM_BYTES * 2 - 1:NUM_BYTES] = in_data;
            next_keep[NUM_BYTES * 2 - 1:NUM_BYTES] = in_keep;
        end else begin
            next_data[NUM_BYTES - 1:0] = in_data;
            next_keep[NUM_BYTES - 1:0] = in_keep;
        end
    end
    next_last_received = in.last;
end

// ------- State machine ---------
function offset_t trim_offset(offset_t offset);
    // trim_offset = offset >= NUM_BYTES ? offset - NUM_BYTES : offset;
    trim_offset = offset[$bits(offset_t) - 2:0];
endfunction

task store_input();
    data <= next_data;
    keep <= next_keep;
    last_received <= next_last_received;

    store_in_second_half <= ~store_in_second_half;
endtask

task update_offset(input offset_t next_offset);
    `ifndef SYNTHESIS
    if (next_offset < offset) begin
        $fatal(1, "Attempted to decrement offset in update_offset, going from %d to %d", offset, next_offset);
    end
    `endif

    // If the new offset is beyond the midpoint of the data buffer, which
    // holds two databeats, then we rewrite the offset and move the second
    // half of the buffer into the first, zeroing the second.
    if (next_offset >= NUM_BYTES) begin
        data[NUM_BYTES - 1:0] <= data[NUM_BYTES * 2 - 1:NUM_BYTES];
        keep[NUM_BYTES - 1:0] <= keep[NUM_BYTES * 2 - 1:NUM_BYTES];

        data[NUM_BYTES * 2 - 1:NUM_BYTES] <=  '{default: 'x};
        keep[NUM_BYTES * 2 - 1:NUM_BYTES] <=  '0;

        store_in_second_half <= ~store_in_second_half;

        if (varint_offset >= NUM_BYTES) begin
            varint_offset <= trim_offset(varint_offset);
        end
    end
    offset <= trim_offset(next_offset);
endtask

task reset();
    state <= ST_IDLE;
    data <= 'x;
    keep <= '0;
    last_received <= '0;
    store_in_second_half <= 0;

    bit_width <= 'x;
    bit_width_bpe_mask <= 'x;
    packed_databeat_bits <= 'x;
    packed_databeat_bytes <= 'x;
    eight_packed_databeat_bytes <= 'x;
    varint_offset <= 'x;
    varint_in.valid <= 0;
    offset <= 'x;
    remaining_values <= 'x;

    rle_width <= 'x;
    rle_count <= 'x;
    bpe_count <= 'x;
endtask

task goto_decode(input data32_t remaining_values, input offset_t varint_offst);
    logic less_remaining_values_than_next_bpe_count;
    bpe_count_t next_bpe_count, next_bpe_padded_count;
    offset_t offset_after_varint;

    // The first byte after the varint
    offset_after_varint = varint_offst + varint_out.data.length;

    less_remaining_values_than_next_bpe_count = remaining_values < varint_no_encoding_bytes;
    next_bpe_count = less_remaining_values_than_next_bpe_count ? remaining_values : varint_no_encoding_bytes;
    next_bpe_padded_count = varint_no_encoding_bytes;

    `ifndef SYNTHESIS
    if (~varint_out.valid) begin
        $fatal(1, "Called goto_decode() when varint_out.valid = %b", varint_out.valid);
    end
    `endif

    update_offset(offset_after_varint);
    if (varint_encoding == ENCODING_BPE) begin
        state <= ST_DECODE_BPE;

        // Compute BPE properties
        bpe_count <= next_bpe_count;

        goto_decode_bpe(next_bpe_padded_count, offset_after_varint);
    end else begin
        // Compute RLE properties
        rle_count <= varint_no_encoding;

        goto_decode_rle(offset_after_varint);
    end
endtask

task goto_decode_bpe(
    input bpe_count_t bpe_padded_cnt,
    input offset_t offst
);
    bpe_remaining_inputs_t next_bpe_remaining_inputs; 
    logic [$clog2(NUM_ELEMENTS) - 1:0] values_in_extra_input;
    offset_t next_varint_offset_increment_extra, next_varint_offset_increment;
    header_offset_t next_varint_offset;

    next_bpe_remaining_inputs = bpe_padded_cnt / NUM_ELEMENTS;
    values_in_extra_input = bpe_padded_cnt % NUM_ELEMENTS;
    next_varint_offset_increment_extra = values_in_extra_input > 0 ? eight_packed_databeat_bytes : 0;
    next_varint_offset_increment = (next_bpe_remaining_inputs * packed_databeat_bytes) + next_varint_offset_increment_extra;
    next_varint_offset = offst + next_varint_offset_increment;

    `ifndef SYNTHESIS
    if (next_varint_offset_increment != offset_t'((bpe_padded_cnt * bit_width) / 8)) begin
        $fatal(1, "goto_decode_bpe() computed the wrong next_varint_offset_increment, expected %d, got %d", offset_t'((bpe_padded_cnt * bit_width) / 8), next_varint_offset_increment);
    end
    `endif

    `ifndef SYNTHESIS
    if (offset_t'(next_varint_offset) != offset_t'(offst + ((bpe_padded_cnt * bit_width) / 8))) begin
        $fatal(1, "goto_decode_bpe() computed the wrong next_varint_offset, expected %d, got %d", offset_t'(offst + ((bpe_padded_cnt * bit_width) / 8)), offset_t'(next_varint_offset));
    end
    `endif

    // BPE could contain so many values that the offset would go beyond two
    // databeats, in that case, we set the varint position but we don't make
    // it valid.
    varint_offset <= trim_offset(next_varint_offset);
    bpe_remaining_inputs <= next_bpe_remaining_inputs;

    if (next_bpe_remaining_inputs <= 1) begin
        // Here we use next_varint_offset (which may be > NUM_BYTES) as if
        // that's the case, in this databeat we also moved the offset forward
        // and shifted the data, so we store the varint_offset trimmed
        // (outside of this loop) but compute the correct varint_in data to
        // match.
        update_varint_data(data, next_varint_offset);
        varint_in.valid <= next_varint_valid(keep, last_received, next_varint_offset);
    end else begin
        varint_in.valid <= 0;
    end

    state <= ST_DECODE_BPE;
endtask

task advance_bpe();
    bpe_count_t next_bpe_count;
    bpe_remaining_inputs_t  next_bpe_remaining_inputs;
    offset_t next_offset;

    next_bpe_count = bpe_count - NUM_ELEMENTS;
    next_bpe_remaining_inputs = bpe_remaining_inputs - 1;
    next_offset = offset + packed_databeat_bytes;

    bpe_count <= next_bpe_count;
    remaining_values <= remaining_values - NUM_ELEMENTS;
    bpe_remaining_inputs <= next_bpe_remaining_inputs;
    update_offset(next_offset);

    `ifndef SYNTHESIS
    if (bpe_remaining_inputs == 0 || bpe_in.last) begin
        $fatal(1, "advance_decode() has been called on the final BPE input");
    end
    `endif

    if (bpe_remaining_inputs == 1) begin
        logic [$bits(offset_t):0] next_next_offset;
        logic increment_varint_offset;
        offset_t actual_varint_offset;
        logic next_varint_in_valid;

        next_next_offset = next_offset + packed_databeat_bytes;
        // The varint offset for the next next cycle, when the next and final
        // bpe encoded chunks will have been decoded, depends on whether we're
        // moving the next_offset beyond NUM_BYTES (and thus shifting the
        // value in `data` by 512 bits) or not. If that's the case we want to
        // use a +64byte offest as in the current cycle the shift has not
        // happened yet.
        //
        // The `next_offset > varint_offset` condition ensures that we're only
        // looking into the second input half if the next offset is beyond the
        // varint_offset, meaning that it is in the second half of the stream.
        // The varint offset shall never be > 64.
        increment_varint_offset = next_offset > varint_offset && next_next_offset >= NUM_BYTES;
        actual_varint_offset = increment_varint_offset ? varint_offset + NUM_BYTES : varint_offset;
        next_varint_in_valid = next_varint_valid(keep, last_received, actual_varint_offset);

        update_varint_data(data, actual_varint_offset);
        varint_in.valid <= next_varint_in_valid;

        // We only want to store the offset if we haven't trimmed the input in
        // this cycle and if we haven't set a valid varint input already.
        // Note that if we have just trimmed the output, the varint_offset is
        // already correct.
        if (~next_varint_in_valid && next_offset < NUM_BYTES) begin
            varint_offset <= actual_varint_offset;
        end
    end
endtask

task finish_bpe();
    data32_t next_remaining_values;
    next_remaining_values = remaining_values - bpe_count;

    remaining_values <= next_remaining_values;
    if (next_remaining_values == 0) begin
        reset();
    end else if (varint_out.valid) begin
        // If the varint for the next databeat is already valid and parsed, we can
        // move forward to the next decode, otherwise we store the varint offset
        // which we're trying to decode and move to a state waiting for more input).
        // current_varint_offset is relative to the not yet shifted buffer, so
        // update_offset() performs the shift if the varint is in the second half.
        goto_decode(next_remaining_values, current_varint_offset);
    end else begin
        // NOTE: this update here is needed as this last BPE decoding might
        // have involved receiving more input, meaning that the varint may now
        // be valid. update_offset() then performs the shift if the varint is in
        // the second buffer half, and the varint data is read from the
        // pre-shift location.
        update_varint_data(data, current_varint_offset);
        varint_in.valid <= next_varint_valid(keep, last_received, current_varint_offset);
        update_offset(current_varint_offset);

        // If ~varint_out.valid we need to fetch more input to
        // satisfy it.
        state <= ST_HEADER2;
    end
endtask

task goto_decode_rle(input offset_t offst);
    state <= ST_DECODE_RLE;
    varint_offset <= trim_offset(offst) + rle_width;

    // NOTE: these are using the current offset, not the trimmed value.
    // This is because, if there has been a change in the offset in this cycle,
    // the data will be shifted but only from the next cycle, so when indexing
    // data and keep to populate the varint decoder, we need to use the
    // current offset.
    update_varint_data(data, offst + rle_width);
    varint_in.valid <= next_varint_valid(keep, last_received, offst + rle_width);
endtask

task finish_rle();
    data32_t next_remaining_values;
    next_remaining_values = remaining_values - rle_count;

    remaining_values <= next_remaining_values;
    if (next_remaining_values == 0) begin
        reset();
    end else if (varint_out.valid) begin
        // If the varint for the next databeat is already valid and parsed, we can
        // move forward to the next decode, otherwise we store the varint offset
        // which we're trying to decode and move to a state waiting for more input).
        goto_decode(next_remaining_values, varint_offset);
    end else begin
        // The varint was computed in goto_decode_rle(), but decoding the RLE
        // value might have involved receiving more input, so the varint may now
        // be valid. Moving the offset to the varint also shifts the buffer if
        // the varint is in the second half, so that ST_HEADER2 never stores
        // input into the half that is still in use.
        update_varint_data(data, varint_offset);
        varint_in.valid <= next_varint_valid(keep, last_received, varint_offset);
        update_offset(varint_offset);

        // If ~varint_out.valid we need to fetch more input to
        // satisfy it.
        state <= ST_HEADER2;
    end
endtask

// The header may extend beyond the buffer, in which case it is not valid until the buffer has been
// shifted and the next databeat has been received.
task update_varint_data(input data8_t[NUM_BYTES * 2 - 1:0] new_data, header_offset_t new_offst);
    data8_t[NUM_BYTES * 2 + VARINT_NUM_BYTES - 2:0] padded_data;
    padded_data = new_data;
    varint_in.data <= padded_data[new_offst +: VARINT_NUM_BYTES];
endtask

function next_varint_valid(input logic[NUM_BYTES * 2 - 1:0] keep, logic last_received, header_offset_t offst);
    logic[NUM_BYTES * 2 + VARINT_NUM_BYTES - 2:0] padded_keep;
    padded_keep = keep;
    next_varint_valid = offst < NUM_BYTES * 2 && padded_keep[offst] &&
                        (last_received || (&padded_keep[(offst + 1) +: VARINT_NUM_BYTES - 1]));
endfunction

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        reset();
    end else begin
        if (in.ready && in.valid) begin
            store_input();
        end

        case (state)
            ST_IDLE: begin
                if (conf.ready && conf.valid) begin
                    bit_width <= conf_data.bit_width;
                    bit_width_bpe_mask <= BPE_MASK_SIZE'((1 << conf_data.bit_width) - 1);
                    packed_databeat_bits <= NUM_ELEMENTS * conf_data.bit_width;
                    packed_databeat_bytes <= (NUM_ELEMENTS * conf_data.bit_width) / 8;
                    eight_packed_databeat_bytes <= conf_data.bit_width; // equivalent to (8 * conf_data.bit_width) / 8;
                    rle_width <= (conf_data.bit_width + 7) >> 3;
                    offset <= conf_data.offset;
                    varint_offset <= conf_data.offset;
                    remaining_values <= conf_data.num_values;
                    
                    if (in.valid) begin
                        state <= ST_HEADER2;
                        update_varint_data(in.data, conf_data.offset);
                        varint_in.valid <= next_varint_valid(in.keep, in.last, conf_data.offset);
                    end else begin
                        state <= ST_HEADER;
                    end
                end
            end

            // Here we have received the configuration but we haven't yet
            // received the input. Receiving one databeat may or may not be
            // enough.
            ST_HEADER: begin
                if (in.valid) begin
                    update_varint_data(in.data, varint_offset);
                    varint_in.valid <= next_varint_valid(in.keep, in.last, varint_offset);
                    // If we receive input, the varint decoding is not yet done
                    // as it takes one cycle. Move to the next state so that
                    // we can optionally take even more input if needed for
                    // the varint decoding.
                    state <= ST_HEADER2;
                end
            end

            // Here we have received the configuration and one input databeat,
            // but we weren't able to decode the header varint with just that.
            ST_HEADER2: begin
                if (varint_out.valid) begin
                    goto_decode(remaining_values, varint_offset);
                end else if (in.valid) begin
                    update_varint_data(next_data, varint_offset);
                    varint_in.valid <= next_varint_valid(next_keep, next_last_received, varint_offset);
                end
            end

            ST_DECODE_RLE: begin
                if (rle_in.ready && rle_in.valid) begin
                    finish_rle();
                end
            end

            ST_DECODE_BPE: begin
                if (bpe_in.ready && bpe_in.valid) begin
                    if (bpe_in.last) begin
                        finish_bpe();
                    end else begin
                        advance_bpe();
                    end
                end
            end
        endcase
    end
end

// ------- Driving input ---------
always_comb begin
    // We need to provide default values to prevent latch inference
    conf.ready = state == ST_IDLE; 

    in.ready = 0;
    case (state)
        ST_IDLE:
            in.ready = conf.valid;

        ST_HEADER, ST_HEADER2:
            in.ready = ~varint_in.valid;

        ST_DECODE_RLE:
            in.ready = rle_needs_more_input;
            
        ST_DECODE_BPE:
            in.ready = bpe_needs_more_input;
    endcase
end

// ------- Driving output --------
localparam FIFO_DEPTH = MAX_IN_TRANSIT * 8;

logic fifo_out_ready;
logic[$clog2(FIFO_DEPTH):0] filling_level;
MehdiFIFO #(
    .DEPTH(FIFO_DEPTH),
    .WIDTH($bits(output_t))
) inst_output_fifo (
    .i_clk(clk),
    .i_rst_n(reset_synced),

    .i_data(next_out.data),
    .i_valid(next_out.valid),
    .i_ready(can_decode_next),

    .o_data(curr_out.data),
    .o_valid(curr_out.valid),
    .o_ready(fifo_out_ready),

    .o_filling_level(filling_level)
);

always_comb begin
    rle_out.ready = 0;
    bpe_out.ready = 0;
    out.valid = 0;
    out.data = '{default: 'x};
    out.keep = '0;
    out.last = 0;
    fifo_out_ready = 0;

    if (curr_out.valid) begin
        case (curr_out.data)
            OUTPUT_RLE: begin
              rle_out.ready = out.ready;
              out.valid = rle_out.valid;
              out.data = rle_out.data;
              out.keep = rle_out.keep;
              out.last = rle_out.last;
              fifo_out_ready = out.ready && out.valid && out.last;
            end

            OUTPUT_BPE: begin
              bpe_out.ready = out.ready;
              out.valid = bpe_out.valid;
              out.data = bpe_out.data;
              out.keep = bpe_out.keep;
              out.last = bpe_out.last;
              fifo_out_ready = out.ready && out.valid;
            end
        endcase
    end
end

// `ifdef SYNTHESIS
// ila_run_decoder inst_ila_run_decoder (
//     .clk(clk),
//     .probe0(reset_synced),
//
//     .probe1(conf.ready),
//     .probe2(conf.valid),
//
//     .probe3(in.ready),
//     .probe4(in.valid),
//     .probe5(in.last),
//
//     .probe6(out.ready),
//     .probe7(out.valid),
//     .probe8(out.last),
//
//     .probe9(state),
//     .probe10(offset),
//     .probe11(varint_offset),
//     .probe12(varint_in.valid),
//     .probe13(varint_in.data),
//     .probe14(varint_out.valid),
//     .probe15(varint_out.data),
//
//     .probe16(remaining_values),
//     .probe17(bpe_count),
//     .probe18(bpe_remaining_inputs),
//     .probe19(rle_width),
//     .probe20(rle_count),
//
//     .probe21(bpe_in.ready),
//     .probe22(bpe_in.valid),
//     .probe23(bpe_in.last),
//
//     .probe24(rle_in.ready),
//     .probe25(rle_in.valid),
//     .probe26(rle_in.last),
//
//     .probe27(bpe_out.ready),
//     .probe28(bpe_out.valid),
//     .probe29(bpe_out.last),
//
//     .probe30(rle_out.ready),
//     .probe31(rle_out.valid),
//     .probe32(rle_out.last),
//
//     .probe33(next_out.valid),
//     .probe34(next_out.data),
//     .probe35(can_decode_next),
//
//     .probe36(curr_out.valid),
//     .probe37(curr_out.data),
//     .probe38(fifo_out_ready),
//
//     .probe39(filling_level)
// );
// `endif

endmodule
