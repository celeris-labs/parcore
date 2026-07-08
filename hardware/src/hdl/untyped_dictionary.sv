`timescale 1ns / 1ps

import libstf::*;

module UntypedDictionary #(
    parameter type id_t,
    parameter DATABEAT_SIZE,
    parameter type UNDERLYING_DATA_T = data32_t,
    parameter int DICTIONARY_WORD_SIZE = $bits(UNDERLYING_DATA_T) / 8,
    parameter NUM_ELEMENTS = DATABEAT_SIZE / DICTIONARY_WORD_SIZE,
    parameter NUM_BANKS = 16
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in_body,  // #(data8_t, DATABEAT_SIZE)
    ndata_i.s in_ids,   // #(id_t, NUM_ELEMENTS)

    ndata_i.m out       // #(data8_t, DATABEAT_SIZE)
);

`ASSERT_ELAB(DATABEAT_SIZE == NUM_ELEMENTS * DICTIONARY_WORD_SIZE)

valid_i #(type_t) typ(clk, rst_n);


ndata_i #(UNDERLYING_DATA_T, NUM_ELEMENTS) body_converted (clk, rst_n);
ndata_i #(UNDERLYING_DATA_T, NUM_ELEMENTS) dictionary_out(clk, rst_n);
generate
for (genvar i = 0; i < NUM_ELEMENTS; i++) begin
    assign body_converted.data[i] = in_values.data[i * TYPED_DICTIONARY_DATA_SIZE +: TYPED_DICTIONARY_DATA_SIZE];
    assign body_converted.keep[i] = &in_values.keep[i * TYPED_DICTIONARY_DATA_SIZE];
end
endgenerate
assign _body_converted.ready = in_body.ready;
assign in_body.valid = _body_converted.valid;

Dictionary #(
    .value_t(UNDERLYING_DATA_T),
    .id_t(id_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .NUM_BANKS(NUM_BANKS)
) inst_dictionary (
    .clk(clk),
    .rst_n(rst_n),

    .in_values(body_converted),
    .in_ids(in_ids),

    .out(dictionary_out)
);

assign dictionary_out.ready = out.ready;
generate
for (genvar i = 0; i < NUM_ELEMENTS; i++) begin
    assign out.data[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE] = dictionary_out.data[i];
    assign out.keep[(i+1) * TYPED_DICTIONARY_DATA_SIZE - 1:i * TYPED_DICTIONARY_DATA_SIZE] = {TYPED_DICTIONARY_DATA_SIZE{dictionary_out.keep[i]}};
end
endgenerate
assign out.last = dictionary_out.last;
assign out.valid = typ.valid && dictionary_out.valid;

endmodule
