`timescale 1ns / 1ps

`include "libstf_macros.svh"

import libstf::*;

/**
 * Packs the heap bytes of all pages of a string column chunk into full beats. Pages that produce no
 * heap pass no data. If the last page is one of them, a dummy beat carries the chunk's last.
 */
module HeapNormalizer #(
    parameter NUM_BYTES = AXI_DATA_BITS / 8,
    parameter COMPACTOR_REGISTER_LEVELS = 3,
    parameter BARREL_SHIFTER_REGISTER_LEVELS = 2
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s conf, // logic [1:0] = {generates_heap, last_page}

    ndata_i.s in,         // #(data8_t, NUM_BYTES) heap bytes selected by keep
    ndata_i.m out         // #(data8_t, NUM_BYTES)
);

logic generates_heap;
logic last_page;

typedef enum logic[1:0] { 
    WAIT_CONF,
    PASSTHROUGH,
    EMIT_DUMMY
} state_t;

state_t state;
ndata_i #(data8_t, NUM_BYTES) to_normalizer (.*);

task fetch_conf_transition();
    generates_heap <= conf.data[1];
    last_page <= conf.data[0];
    if (conf.data[1])
        state <= PASSTHROUGH;
    else if (conf.data[0])
        state <= EMIT_DUMMY;
    else
        state <= WAIT_CONF;
endtask

always_ff @( posedge clk ) begin
if (!rst_n) begin
    state <= WAIT_CONF;
end else begin
    case (state)
        WAIT_CONF: begin
            if (conf.valid)
                fetch_conf_transition();
        end
        EMIT_DUMMY: begin
            if (to_normalizer.ready)
                state <= WAIT_CONF;
        end
        PASSTHROUGH: begin
            if (in.valid && in.last && to_normalizer.ready) begin
                state <= WAIT_CONF;
            end
        end
    endcase
end
end

assign conf.ready = state == WAIT_CONF;
assign to_normalizer.data = in.data;
assign to_normalizer.keep = state == PASSTHROUGH ? in.keep : '0;
assign to_normalizer.valid = (state == PASSTHROUGH && in.valid) || state == EMIT_DUMMY;
assign to_normalizer.last = state == EMIT_DUMMY || (state == PASSTHROUGH && in.last && last_page);
assign in.ready = state == PASSTHROUGH && to_normalizer.ready;

DataNormalizer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_BYTES),
    // The ParallelStringDecoder only keeps the heap bytes of every beat
    .ENABLE_COMPACTOR(1),
    .COMPACTOR_REGISTER_LEVELS(COMPACTOR_REGISTER_LEVELS),
    .BARREL_SHIFTER_REGISTER_LEVELS(BARREL_SHIFTER_REGISTER_LEVELS)
) inst_normalizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(to_normalizer),
    .out(out)
);


endmodule
