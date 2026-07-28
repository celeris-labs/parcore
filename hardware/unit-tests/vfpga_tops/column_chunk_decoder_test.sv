`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::data8_t;

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

ndata_i #(data8_t, 64) in(clk, rst_n);
AXIToNData #(data8_t, 64) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(in)
);

/* -- OUTPUT ------------------------------------------------------------ */

AXI4S axi_host_send_0 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0])

ndata_i #(data8_t, 64) out_u8(clk, rst_n);
NDataToAXI #(data8_t, 64) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_u8),
    .out(axi_host_send_0)
);

ndata_i #(data8_t, 64) out(clk, rst_n);
`DATA_ASSIGN(out, out_u8);

// String heap: only carries data for german strings longer than 12 bytes, so it
// stays idle for fixed-width chunks.
AXI4S axi_host_send_1 (.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_1, axis_host_send[1])

ndata_i #(data8_t, 64) heap_u8(clk, rst_n);
NDataToAXI #(data8_t, 64) inst_ndata_to_axi_heap (
    .clk(clk),
    .rst_n(rst_n),

    .in(heap_u8),
    .out(axi_host_send_1)
);

ndata_i #(data8_t, 64) heap_out(clk, rst_n);
`DATA_ASSIGN(heap_out, heap_u8);

/* -- DESIGN WIRING ----------------------------------------------------- */

ColumnChunkDecoder #(
    .DATABEAT_SIZE(64)
) inst_column_chunk_decoder (
    .clk(clk),
    .rst_n(rst_n),

    .conf(column_chunk_conf[0]),

    .in(in),
    .out(out),
    .heap_out(heap_out),

    .profile(profile[0])
);
