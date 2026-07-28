`timescale 1ns / 1ps

import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"

/**
 * Writes 2 * N_CHANNELS output streams to host memory over N_CHANNELS physical
 * Coyote channels: each channel I carries a (values, heap) StreamWriter pair
 * for decoder I, merged by a StreamWriterPairArbiter. Streams are indexed
 * writer-first: stream 2I = decoder I values, stream 2I + 1 = decoder I heap;
 * this is also the mem_config slot and the interrupt stream id
 * (notify value[2:0]), while the request `dest` stays the channel index I.
 *
 * IMPORTANT:
 * This component assumes normalized streams.
 * E.g. the keep signal should be all 1s, except for data beats that contain a
 * last signal.
 */
module PairedOutputWriter #(
    parameter N_CHANNELS = N_STRM_AXI
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,
    metaIntf.m notify,

    mem_config_i.s mem_config[2 * N_CHANNELS],

    AXI4S.s  data_in[2 * N_CHANNELS],
    AXI4SR.m data_out[N_CHANNELS]
);

`RESET_RESYNC // Reset pipelining

`ifndef SYNTHESIS
for (genvar I = 0; I < 2 * N_CHANNELS; I++) begin
    assert property (@(posedge clk) disable iff (!reset_synced)
        !data_in[I].tvalid || data_in[I].tlast || &data_in[I].tkeep)
    else $fatal(1, "Non-last keep signal (%h) must be all 1s!", data_in[I].tkeep);
    assert property (@(posedge clk) disable iff (!reset_synced)
        !data_in[I].tvalid || !data_in[I].tlast || $onehot0(data_in[I].tkeep + 1'b1))
    else $fatal(1, "Last keep signal (%h) must be contiguous starting from the least significant bit!", data_in[I].tkeep);
end
`endif

// -- Channel-level arbitration ---------------------------------------------
metaIntf #(.STYPE(req_t))     sq_wr_chan  [N_CHANNELS]    (.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(ack_t))     cq_wr_chan  [N_CHANNELS]    (.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(irq_not_t)) notify_strm [2 * N_CHANNELS](.aclk(clk), .aresetn(reset_synced));

MetaIntfArbiter #(
  .N_INTERFACES(N_CHANNELS),
  .STYPE(req_t)
) inst_sq_wr_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(sq_wr_chan),
  .intf_out(sq_wr)
);

CQDemultiplexer #(
  .N_STREAMS(N_CHANNELS)
) inst_cq_wr_de_mux (
  .clk(clk),
  .rst_n(reset_synced),
  .data_in(cq_wr),
  .data_out(cq_wr_chan)
);

MetaIntfArbiter #(
  .N_INTERFACES(2 * N_CHANNELS),
  .STYPE(irq_not_t)
) inst_notify_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(notify_strm),
  .intf_out(notify)
);

// -- Writer pairs, one per physical channel ---------------------------------
for (genvar I = 0; I < N_CHANNELS; I++) begin : gen_pairs
    metaIntf #(.STYPE(req_t)) sq_wr_pair[2](.aclk(clk), .aresetn(reset_synced));
    metaIntf #(.STYPE(ack_t)) cq_wr_pair[2](.aclk(clk), .aresetn(reset_synced));
    AXI4SR data_pair[2](.aclk(clk), .aresetn(reset_synced));

    for (genvar J = 0; J < 2; J++) begin : gen_writers
        StreamWriter #(
            .AXI_STRM_ID(I),
            .IRQ_STREAM_ID(2 * I + J),
            .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE_BYTES)
        ) inst_stream_writer (
            .clk(clk),
            .rst_n(reset_synced),

            .sq_wr(sq_wr_pair[J]),
            .cq_wr(cq_wr_pair[J]),
            .notify(notify_strm[2 * I + J]),

            .mem_config(mem_config[2 * I + J]),

            .input_data(data_in[2 * I + J]),
            .output_data(data_pair[J])
        );
    end

    StreamWriterPairArbiter inst_pair_arbiter (
        .clk(clk),
        .rst_n(reset_synced),

        .sq_wr_in(sq_wr_pair),
        .cq_wr_out(cq_wr_pair),
        .data_in(data_pair),

        .sq_wr_out(sq_wr_chan[I]),
        .cq_wr_in(cq_wr_chan[I]),
        .data_out(data_out[I])
    );

`ifdef SYNTHESIS
    // Both writers of the pair ([0] = values, [1] = heap) plus the merged
    // channel traffic. Each StreamWriter's FSM state is inferable from its
    // handshakes: buffer_ready high = WAIT_FOR_BUFFER, sq valid = REQUEST,
    // data flowing = TRANSFER, notify valid = WAIT_NOTIFY, everything quiet
    // with buffer_ready low = WAIT_COMPLETION (acks missing).
    ila_paired_writer inst_ila_paired_writer (
        .clk(clk),
        .probe0(reset_synced),

        .probe1({sq_wr_pair[0].valid, sq_wr_pair[0].ready}),
        .probe2({sq_wr_pair[1].valid, sq_wr_pair[1].ready}),
        .probe3({data_pair[0].tvalid, data_pair[0].tready, data_pair[0].tlast}),
        .probe4({data_pair[1].tvalid, data_pair[1].tready, data_pair[1].tlast}),
        .probe5({cq_wr_pair[0].valid, cq_wr_pair[0].ready}),
        .probe6({cq_wr_pair[1].valid, cq_wr_pair[1].ready}),
        .probe7({notify_strm[2*I].valid, notify_strm[2*I].ready}),
        .probe8({notify_strm[2*I+1].valid, notify_strm[2*I+1].ready}),
        .probe9({mem_config[2*I].buffer_valid, mem_config[2*I].buffer_ready,
                 mem_config[2*I].flush_buffers}),
        .probe10({mem_config[2*I+1].buffer_valid, mem_config[2*I+1].buffer_ready,
                  mem_config[2*I+1].flush_buffers}),

        .probe11({sq_wr_chan[I].valid, sq_wr_chan[I].ready}),
        .probe12(sq_wr_chan[I].data.len),
        .probe13(sq_wr_chan[I].data.vaddr[31:0]),
        .probe14({cq_wr_chan[I].valid, cq_wr_chan[I].ready}),
        .probe15({data_out[I].tvalid, data_out[I].tready, data_out[I].tlast})
    );
`endif
end

endmodule
