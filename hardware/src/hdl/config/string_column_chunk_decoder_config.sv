`timescale 1ns / 1ps

import libstf::*;
import parcore::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

/**
 * Register NUM_DECODERS + I takes the heap address of the next string column chunk of decoder I.
 */
module StringColumnChunkDecoderConfig #(
    parameter NUM_DECODERS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    ready_valid_i.m out[NUM_DECODERS],       // #(column_chunk_conf_t)
    ready_valid_i.m heap_addrs[NUM_DECODERS], // #(vaddress_t)

    decoder_profile_i.s profile[NUM_DECODERS]
);

localparam MAX_NUM_ENQUEUED_BUFFERS = 64;

`RESET_RESYNC // Reset pipelining

ColumnChunkDecoderConfig #(
    .NUM_DECODERS(NUM_DECODERS),
    .HAS_STRING_DECODERS(1)
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_config),
    .read_config(read_config),

    .out(out),

    .profile(profile)
);

for (genvar I = 0; I < NUM_DECODERS; I++) begin
    ConfigWriteFIFO #(
        NUM_DECODERS + I,
        MAX_NUM_ENQUEUED_BUFFERS,
        vaddress_t
    ) inst_heap_addr (
        clk,
        reset_synced,
        write_config,
        heap_addrs[I]
    );
end

endmodule
