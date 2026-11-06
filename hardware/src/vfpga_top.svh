`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

localparam N_STREAMS = N_STRM_AXI;
localparam DATABEAT_SIZE = 64;
localparam AXI_DATA_SIZE = 64;

// Decode german strings. Each decoder then also writes its string heap.
localparam ENABLE_STRINGS = 1;

// Pipeline depth on every stream between the shell (SLR0) and a decoder. Matches
// N_STAGES_0 in Coyote's dcpl_static.sv, which crosses a comparable distance.
localparam AXIS_CROSSING_STAGES = 3;

/* -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

/* -- CONFIG ------------------------------------------------------------ */
// Decoder I writes its values on output stream STREAMS_PER_DECODER * I and, with strings, its heap
// on the stream after. Both share host stream I (see OutputWriter).
localparam int STREAMS_PER_DECODER = ENABLE_STRINGS ? 2 : 1;
localparam int NUM_OUTPUTS = STREAMS_PER_DECODER * N_STREAMS;
localparam int STREAMS_PER_CHANNEL[N_STREAMS] = '{default: STREAMS_PER_DECODER};

// MemConfig has a write register per stream plus flush and 4 read registers.
localparam MEM_CONFIG_REGS = NUM_OUTPUTS + 1 > 4 ? NUM_OUTPUTS + 1 : 4;

write_config_i write_configs[2](.*);
read_config_i  read_configs [2](.*);
GlobalConfig #(
    .SYSTEM_ID(PARCORE_SYSTEM_ID),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({MEM_CONFIG_REGS, COLUMN_CHUNK_DECODER_READ_REGS(N_STREAMS)})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_conf[NUM_OUTPUTS](.*);
MemConfig #(
    .NUM_STREAMS(NUM_OUTPUTS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

decoder_profile_i profile[N_STREAMS]();

/* -- INPUT ------------------------------------------------------------- */
ndata_i #(data8_t, DATABEAT_SIZE) dec_in[N_STREAMS](clk, rst_n);

for (genvar I = 0; I < N_STREAMS; I++) begin : gen_inputs
    AXI4S axi_host_recv (.aclk(clk), .aresetn(rst_n));
    `AXIS_ASSIGN(axis_host_recv[I], axi_host_recv)

    AXI4S axi_host_recv_piped (.aclk(clk), .aresetn(rst_n));
    axis_reg_array #(
        .N_STAGES(AXIS_CROSSING_STAGES)
    ) inst_recv_pipe (
        .aclk(clk),
        .aresetn(rst_n),

        .s_axis(axi_host_recv),
        .m_axis(axi_host_recv_piped)
    );

    ndata_i #(data8_t, AXI_DATA_SIZE) _in(clk, rst_n);
    AXIToNData #(data8_t, AXI_DATA_SIZE) inst_axi_to_ndata (
        .clk(clk),
        .rst_n(rst_n),

        .in(axi_host_recv_piped),
        .out(_in)
    );

    NDataWidthConverter #(data8_t) in_resizer (
        .clk(clk),
        .rst_n(rst_n),

        .in(_in),
        .out(dec_in[I])
    );
end

/* -- DECODERS ---------------------------------------------------------- */
ndata_i #(data8_t, DATABEAT_SIZE) dec_outs[NUM_OUTPUTS](clk, rst_n);

if (ENABLE_STRINGS) begin : gen_string_decoders
    ready_valid_i #(column_chunk_conf_t) column_chunk_conf[N_STREAMS](.*);
    ready_valid_i #(vaddress_t) heap_addrs[N_STREAMS](.*);
    StringColumnChunkDecoderConfig #(
        .NUM_DECODERS(N_STREAMS)
    ) inst_column_chunk_decoder_config (
        .clk(clk),
        .rst_n(rst_n),

        .write_config(write_configs[1]),
        .read_config(read_configs[1]),

        .out(column_chunk_conf),
        .heap_addrs(heap_addrs),

        .profile(profile)
    );

    for (genvar I = 0; I < N_STREAMS; I++) begin : gen
        StringColumnChunkDecoder #(
            .DATABEAT_SIZE(DATABEAT_SIZE)
        ) inst_column_chunk_decoder (
            .clk(clk),
            .rst_n(rst_n),

            .conf(column_chunk_conf[I]),
            .heap_addr(heap_addrs[I]),

            .in(dec_in[I]),
            .out(dec_outs[2 * I]),
            .heap_out(dec_outs[2 * I + 1]),

            .profile(profile[I])
        );
    end
end else begin : gen_decoders
    ready_valid_i #(column_chunk_conf_t) column_chunk_conf[N_STREAMS](.*);
    ColumnChunkDecoderConfig #(
        .NUM_DECODERS(N_STREAMS)
    ) inst_column_chunk_decoder_config (
        .clk(clk),
        .rst_n(rst_n),

        .write_config(write_configs[1]),
        .read_config(read_configs[1]),

        .out(column_chunk_conf),

        .profile(profile)
    );

    for (genvar I = 0; I < N_STREAMS; I++) begin : gen
        ColumnChunkDecoder #(
            .DATABEAT_SIZE(DATABEAT_SIZE)
        ) inst_column_chunk_decoder (
            .clk(clk),
            .rst_n(rst_n),

            .conf(column_chunk_conf[I]),

            .in(dec_in[I]),
            .out(dec_outs[I]),

            .profile(profile[I])
        );
    end
end

/* -- OUTPUT ------------------------------------------------------------ */
AXI4S outputs[NUM_OUTPUTS](.aclk(clk), .aresetn(rst_n));

for (genvar I = 0; I < NUM_OUTPUTS; I++) begin : gen_outputs
    ndata_i #(data8_t, AXI_DATA_SIZE) dec_out_resized(clk, rst_n);
    NDataWidthConverter #(data8_t) out_resizer (
        .clk(clk),
        .rst_n(rst_n),

        .in(dec_outs[I]),
        .out(dec_out_resized)
    );

    AXI4S axi_out (.aclk(clk), .aresetn(rst_n));
    NDataToAXI #(data8_t, AXI_DATA_SIZE) inst_out_to_axi (
        .clk(clk),
        .rst_n(rst_n),

        .in(dec_out_resized),
        .out(axi_out)
    );

    axis_reg_array #(
        .N_STAGES(AXIS_CROSSING_STAGES)
    ) inst_out_pipe (
        .aclk(clk),
        .aresetn(rst_n),

        .s_axis(axi_out),
        .m_axis(outputs[I])
    );
end

OutputWriter #(
    .STREAMS_PER_CHANNEL(STREAMS_PER_CHANNEL),
    .NUM_STREAMS(NUM_OUTPUTS)
) inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(outputs),
    .data_out(axis_host_send),

    .notify_count() // Unused
);
