`include "lynx_macros.svh"
`include "libstf_macros.svh"

import parcore::*;
import libstf::*;

/* -- Tie-off unused interfaces and signals ----------------------------- */
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

localparam N_STREAMS = N_STRM_AXI;
localparam DATABEAT_SIZE = 32;
localparam AXI_DATA_SIZE = 64;

// Pipeline depth on every stream between the shell (SLR0) and a decoder. Matches
// N_STAGES_0 in Coyote's dcpl_static.sv, which crosses a comparable distance.
localparam AXIS_CROSSING_STAGES = 3;

/* -- Fix clock and reset names ----------------------------------------- */
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

/* -- CONFIG ------------------------------------------------------------ */
// Two output streams per decoder: values on stream 2I, heap on stream 2I+1.
// Both share physical channel I (see PairedOutputWriter).
write_config_i write_configs[2](.*);
read_config_i  read_configs [2](.*);
GlobalConfig #(
    .SYSTEM_ID(PARCORE_SYSTEM_ID),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({2*N_STREAMS+1, COLUMN_CHUNK_DECODER_READ_REGS(N_STREAMS)})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_conf[2*N_STREAMS](.*);
MemConfig #(
    .NUM_STREAMS(2*N_STREAMS)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_conf)
);

decoder_profile_i profile[N_STREAMS]();

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

AXI4S outputs [2*N_STREAMS](.aclk(clk), .aresetn(rst_n));

generate
    for (genvar I = 0; I < N_STREAMS; I++) begin : gen
        /* -- INPUT ------------------------------------------------------------- */

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

        ndata_i #(data8_t, DATABEAT_SIZE) in(clk, rst_n);
        NDataWidthConverter #(data8_t) in_resizer (
            .clk(clk),
            .rst_n(rst_n),

            .in(_in),
            .out(in)
        );


        /* -- OUTPUT ------------------------------------------------------------ */

        ndata_i #(data8_t, DATABEAT_SIZE) dec_out(clk, rst_n);
        ndata_i #(data8_t, AXI_DATA_SIZE) dec_out_resized (clk, rst_n);

        // Values -> stream 2I.
        AXI4S axi_values (.aclk(clk), .aresetn(rst_n));
        NDataToAXI #(data8_t, AXI_DATA_SIZE) inst_values_to_axi (
            .clk(clk),
            .rst_n(rst_n),

            .in(dec_out_resized),
            .out(axi_values)
        );
        axis_reg_array #(
            .N_STAGES(AXIS_CROSSING_STAGES)
        ) inst_values_pipe (
            .aclk(clk),
            .aresetn(rst_n),

            .s_axis(axi_values),
            .m_axis(outputs[2*I])
        );

        // Heap -> stream 2I+1.
        ndata_i #(data8_t, DATABEAT_SIZE) dec_heap(clk, rst_n);
        ndata_i #(data8_t, AXI_DATA_SIZE) dec_heap_resized(clk, rst_n);
        AXI4S axi_heap (.aclk(clk), .aresetn(rst_n));
        NDataToAXI #(data8_t, AXI_DATA_SIZE) inst_heap_to_axi (
            .clk(clk),
            .rst_n(rst_n),

            .in(dec_heap_resized),
            .out(axi_heap)
        );
        axis_reg_array #(
            .N_STAGES(AXIS_CROSSING_STAGES)
        ) inst_heap_pipe (
            .aclk(clk),
            .aresetn(rst_n),

            .s_axis(axi_heap),
            .m_axis(outputs[2*I+1])
        );

        /* -- DESIGN WIRING ----------------------------------------------------- */

        ColumnChunkDecoder #(
            .DATABEAT_SIZE(DATABEAT_SIZE)
        ) inst_column_chunk_decoder (
            .clk(clk),
            .rst_n(rst_n),

            .conf(column_chunk_conf[I]),

            .in(in),
            .out(dec_out),
            .heap_out(dec_heap),

            .profile(profile[I])
        );

        NDataWidthConverter #(data8_t) out_resizer (
            .clk(clk),
            .rst_n(rst_n),

            .in(dec_out),
            .out(dec_out_resized)
        );

        NDataWidthConverter #(data8_t) heap_resizer (
            .clk(clk),
            .rst_n(rst_n),

            .in(dec_heap),
            .out(dec_heap_resized)
        );

`ifdef DEBUG
        // Channel-level dataflow boundary: shows which hop of
        // input -> decoder -> values/heap -> writer stops handshaking.
        ila_cc_top inst_ila_cc_top (
            .clk(clk),
            .probe0(rst_n),

            .probe1(column_chunk_conf[I].valid),
            .probe2(column_chunk_conf[I].ready),

            .probe3(axi_host_recv.tvalid),
            .probe4(axi_host_recv.tready),
            .probe5(axi_host_recv.tlast),

            .probe6(in.valid),
            .probe7(in.ready),
            .probe8(in.last),

            .probe9(dec_out.valid),
            .probe10(dec_out.ready),
            .probe11(dec_out.last),

            .probe12(dec_heap.valid),
            .probe13(dec_heap.ready),
            .probe14(dec_heap.last),

            .probe15(outputs[2*I].tvalid),
            .probe16(outputs[2*I].tready),
            .probe17(outputs[2*I].tlast),

            .probe18(outputs[2*I+1].tvalid),
            .probe19(outputs[2*I+1].tready),
            .probe20(outputs[2*I+1].tlast)
        );
`endif
    end
endgenerate

PairedOutputWriter #(
    .N_CHANNELS(N_STREAMS)
) inst_output_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_conf),

    .data_in(outputs),
    .data_out(axis_host_send)
);

`ifdef DEBUG
// Shell-facing writer traffic: every write request (address/length/dest),
// every ack with its identity fields, every notify with pid + value. A hang
// in WAIT_COMPLETION shows as requests without matching acks; a lost
// interrupt shows as a notify handshake the host never reacted to.
ila_shell_io inst_ila_shell_io (
    .clk(clk),
    .probe0(rst_n),

    .probe1(sq_wr.valid),
    .probe2(sq_wr.ready),
    .probe3(sq_wr.data.len),
    .probe4(sq_wr.data.vaddr),
    .probe5(sq_wr.data.dest),
    .probe6(sq_wr.data.last),
    .probe7(sq_wr.data.pid),

    .probe8(cq_wr.valid),
    .probe9(cq_wr.ready),
    .probe10(cq_wr.data.opcode),
    .probe11(cq_wr.data.strm),
    .probe12(cq_wr.data.dest),
    .probe13(cq_wr.data.pid),
    .probe14(cq_wr.data.host),

    .probe15(notify.valid),
    .probe16(notify.ready),
    .probe17(notify.data.pid),
    .probe18(notify.data.value)
);
`endif
