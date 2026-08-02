`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::data8_t;

// column_chunk_decoder_test.sv at DATABEAT_SIZE=32 instead of 64, which is what
// vfpga_top.svh actually instantiates. The AXI streams stay 64 bytes wide, so
// this mirrors vfpga_top's NDataWidthConverter on both sides rather than wiring
// AXIToNData straight to the decoder.

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

// send[1] carries the string heap; recv[1] is unused.
always_comb axis_host_recv[1].tie_off_s();

for (genvar I = 2; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end

/* -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

localparam AXI_DATA_SIZE  = 64;
localparam DATABEAT_SIZE  = 32;

/* -- CONFIG ------------------------------------------------------------ */
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
GlobalConfig #(
    .SYSTEM_ID(PARCORE_SYSTEM_ID),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({COLUMN_CHUNK_DECODER_READ_REGS(1)})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

decoder_profile_i profile[1]();

ready_valid_i #(column_chunk_conf_t) column_chunk_conf[1](.*);
ColumnChunkDecoderConfig #(
    .NUM_DECODERS(1)
) inst_column_chunk_decoder_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(column_chunk_conf),

    .profile(profile)
);

/* -- INPUT ------------------------------------------------------------- */

AXI4S axi_host_recv_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0)

ndata_i #(data8_t, AXI_DATA_SIZE) _in(clk, rst_n);
AXIToNData #(data8_t, AXI_DATA_SIZE) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(_in)
);

ndata_i #(data8_t, DATABEAT_SIZE) in(clk, rst_n);
NDataWidthConverter #(data8_t) in_resizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(_in),
    .out(in)
);

/* -- OUTPUT ------------------------------------------------------------ */

ndata_i #(data8_t, DATABEAT_SIZE) out(clk, rst_n);
ndata_i #(data8_t, AXI_DATA_SIZE)  out_resized(clk, rst_n);

NDataWidthConverter #(data8_t) out_resizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(out),
    .out(out_resized)
);

AXI4S axi_host_send_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

NDataToAXI #(data8_t, AXI_DATA_SIZE) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_resized),
    .out(axi_host_send_0)
);

// String heap: only carries data for german strings longer than 12 bytes, so it
// stays idle for fixed-width chunks.
ndata_i #(data8_t, DATABEAT_SIZE) heap_out(clk, rst_n);
ndata_i #(data8_t, AXI_DATA_SIZE)  heap_resized(clk, rst_n);

NDataWidthConverter #(data8_t) heap_resizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(heap_out),
    .out(heap_resized)
);

AXI4S axi_host_send_1 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_1, axis_host_send[1])

NDataToAXI #(data8_t, AXI_DATA_SIZE) inst_ndata_to_axi_heap (
    .clk(clk),
    .rst_n(rst_n),

    .in(heap_resized),
    .out(axi_host_send_1)
);

/* -- DESIGN WIRING ----------------------------------------------------- */

ColumnChunkDecoder #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_column_chunk_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .conf(column_chunk_conf[0]),

    .in(in),
    .out(out),
    .heap_out(heap_out),

    .profile(profile[0])
);
