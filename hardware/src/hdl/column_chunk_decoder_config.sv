`timescale 1ns / 1ps

import libstf::*;
import parcore::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

interface decoder_profile_i;
    decoder_profile_t counters;
    logic             stop;

    modport m (
        input  stop,
        output counters
    );

    modport s (
        input  counters,
        output stop
    );
endinterface

module ColumnChunkDecoderConfig #(
    parameter NUM_DECODERS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    ready_valid_i.m out[NUM_DECODERS], // #(column_chunk_conf_t)

    decoder_profile_i.s profile[NUM_DECODERS]
);

localparam MAX_NUM_ENQUEUED_BUFFERS = 64;

// Info registers followed by the per-decoder profiling counters. Each decoder
// contributes 10 counters (5 input + 5 output stream profile counters).
localparam NUM_INFO_REGS    = COLUMN_CHUNK_DECODER_INFO_REGS;
localparam NUM_PROFILE_REGS = COLUMN_CHUNK_DECODER_PROFILE_REGS;
localparam NUM_READ_REGS    = COLUMN_CHUNK_DECODER_READ_REGS(NUM_DECODERS);

`RESET_RESYNC // Reset pipelining

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] values[NUM_READ_REGS];
assign values[0] = COLUMN_CHUNK_DECODER_CONFIG_ID;
assign values[1] = NUM_DECODERS;
assign values[2] = MAX_NUM_ENQUEUED_BUFFERS;

decoder_profile_t registered_counters[NUM_DECODERS];

for (genvar I = 0; I < NUM_DECODERS; I++) begin : gen_profile_regs
    ShiftRegister #(
        .WIDTH($bits(decoder_profile_t)),
        .LEVELS(2)
    ) inst_counters_sr (
        .i_clk(clk),
        .i_rst_n(reset_synced),

        .i_data(profile[I].counters),
        .o_data(registered_counters[I])
    );

    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 0] = registered_counters[I].in.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 1] = registered_counters[I].in.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 2] = registered_counters[I].in.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 3] = registered_counters[I].in.idle_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 4] = registered_counters[I].in.last_handshakes;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 5] = registered_counters[I].out.handshakes_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 6] = registered_counters[I].out.starved_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 7] = registered_counters[I].out.stalled_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 8] = registered_counters[I].out.idle_cycles;
    assign values[NUM_INFO_REGS + NUM_PROFILE_REGS * I + 9] = registered_counters[I].out.last_handshakes;
end

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_READ_REGS)
) inst_read_regs (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(values)
);

// -- Profile stop ---------------------------------------------------------------------------------
// The host reads a decoder's 10 profile counters in ascending order. We detect the last read
// handshake and pulse stop[I] so the profilers reset once the full snapshot has been read out.
logic read_handshake;
assign read_handshake = read_config.read_valid && read_config.read_ready;

for (genvar I = 0; I < NUM_DECODERS; I++) begin
    localparam int LAST_PROFILE_REG = NUM_INFO_REGS + NUM_PROFILE_REGS * (I + 1) - 1;
    assign profile[I].stop = read_handshake && (read_config.read_addr == LAST_PROFILE_REG);
end

// -- Write ----------------------------------------------------------------------------------------
for (genvar I = 0; I < NUM_DECODERS; I++) begin
    ConfigWriteFIFO #(I, MAX_NUM_ENQUEUED_BUFFERS, column_chunk_conf_t) inst_conf (clk, reset_synced, write_config, out[I]);
end

endmodule
