`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

/**
 * Shares one physical Coyote write channel between N_WRITERS StreamWriters.
 *
 * All writers are configured with the same AXI_STRM_ID (= the shared channel /
 * request `dest`), so their write requests, data beats, and completions are
 * indistinguishable to the shell. This module keeps them apart:
 *
 * 1. Requests are merged round-robin onto `sq_wr_out`. A request is only
 *    granted while both order FIFOs have space.
 * 2. Data beats must reach the shared channel in exactly the order of the
 *    granted requests. A StreamWriter only issues a request once the whole
 *    transfer sits in its internal FIFO and ends every transfer's data with
 *    `tlast`, so the data mux simply forwards the writer at the head of the
 *    data-order FIFO until a `tlast` beat passes, then pops.
 * 3. Completions arrive on the shared `dest` in request order (one ack per
 *    transfer, `sq_wr.last` is always set) and are routed back to the issuing
 *    writer via the cq-order FIFO.
 *
 * Because a granted transfer is fully buffered inside its writer, the head of
 * the data-order FIFO always drains without depending on the other writers'
 * input progress — no cross-stream head-of-line deadlock.
 */
module StreamWriterPairArbiter #(
    parameter N_WRITERS = 2,
    parameter DATA_ORDER_DEPTH = 8,
    parameter CQ_ORDER_DEPTH = 64
) (
    input logic clk,
    input logic rst_n,

    // Writer side
    metaIntf.s sq_wr_in[N_WRITERS],  // #(req_t)
    metaIntf.m cq_wr_out[N_WRITERS], // #(ack_t)
    AXI4SR.s   data_in[N_WRITERS],

    // Channel side
    metaIntf.m sq_wr_out, // #(req_t)
    metaIntf.s cq_wr_in,  // #(ack_t), pre-routed by dest
    AXI4SR.m   data_out
);

localparam int W = $clog2(N_WRITERS) > 0 ? $clog2(N_WRITERS) : 1;

// ------ Interface unpacking (interface arrays are not dynamically indexable) --
req_t [N_WRITERS - 1:0]                sq_data;
logic [N_WRITERS - 1:0]                sq_valid;

logic [N_WRITERS - 1:0][AXI_DATA_BITS - 1:0]     d_data;
logic [N_WRITERS - 1:0][AXI_DATA_BITS / 8 - 1:0] d_keep;
logic [N_WRITERS - 1:0][PID_BITS - 1:0]          d_tid;
logic [N_WRITERS - 1:0]                          d_last;
logic [N_WRITERS - 1:0]                          d_valid;

logic [N_WRITERS - 1:0] cq_out_ready;

// ------ Command arbitration ----------------------------------------------
logic         scan_valid, grant_valid, grant_fire;
logic [W-1:0] scan_grant, grant, rr;

always_comb begin
    scan_valid = 1'b0;
    scan_grant = '0;

    // Prefer the round-robin pointer onwards, then wrap.
    for (int i = 0; i < N_WRITERS; i++) begin
        if (!scan_valid && i >= 32'(rr) && sq_valid[i]) begin
            scan_grant = W'(i);
            scan_valid = 1'b1;
        end
    end
    for (int i = 0; i < N_WRITERS; i++) begin
        if (!scan_valid && sq_valid[i]) begin
            scan_grant = W'(i);
            scan_valid = 1'b1;
        end
    end
end

// Once offered and stalled, the grant is frozen until the handshake: a
// request arriving on the other writer mid-stall must not retarget the
// already-presented command (metaIntf data must be stable under backpressure).
logic         grant_locked;
logic [W-1:0] grant_held;

assign grant       = grant_locked ? grant_held : scan_grant;
assign grant_valid = grant_locked || scan_valid;

logic data_order_iready, cq_order_iready;

assign sq_wr_out.data  = sq_data[grant];
assign sq_wr_out.valid = grant_valid && data_order_iready && cq_order_iready;
assign grant_fire      = sq_wr_out.valid && sq_wr_out.ready;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        rr           <= '0;
        grant_locked <= 1'b0;
    end else begin
        if (sq_wr_out.valid && !sq_wr_out.ready) begin
            grant_locked <= 1'b1;
            if (!grant_locked) begin
                grant_held <= grant;
            end
        end else begin
            grant_locked <= 1'b0;
        end

        if (grant_fire) begin
            rr <= (grant == W'(N_WRITERS - 1)) ? '0 : grant + 1'b1;
        end
    end
end

// ------ Order FIFOs -------------------------------------------------------
// Pushed together on every granted request; popped independently — the data
// FIFO when the transfer's data has drained, the cq FIFO when its ack arrives.
logic [W-1:0] data_head, cq_head;
logic         data_head_valid, cq_head_valid;
logic         data_pop, cq_pop;

MehdiFIFO #(
    .DEPTH(DATA_ORDER_DEPTH),
    .WIDTH(W)
) inst_data_order_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(grant),
    .i_valid(grant_fire),
    .i_ready(data_order_iready),

    .o_data(data_head),
    .o_valid(data_head_valid),
    .o_ready(data_pop),

    .o_filling_level()
);

MehdiFIFO #(
    .DEPTH(CQ_ORDER_DEPTH),
    .WIDTH(W)
) inst_cq_order_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(grant),
    .i_valid(grant_fire),
    .i_ready(cq_order_iready),

    .o_data(cq_head),
    .o_valid(cq_head_valid),
    .o_ready(cq_pop),

    .o_filling_level()
);

// ------ Data sequencing ---------------------------------------------------
assign data_out.tdata  = d_data[data_head];
assign data_out.tkeep  = d_keep[data_head];
assign data_out.tid    = d_tid[data_head];
assign data_out.tlast  = d_last[data_head];
assign data_out.tvalid = data_head_valid && d_valid[data_head];

assign data_pop = data_out.tvalid && data_out.tready && data_out.tlast;

// ------ Completion routing ------------------------------------------------
assign cq_wr_in.ready = cq_head_valid && cq_out_ready[cq_head];
assign cq_pop         = cq_wr_in.valid && cq_wr_in.ready;

// ------ Per-writer connections --------------------------------------------
for (genvar I = 0; I < N_WRITERS; I++) begin
    assign sq_data[I]  = sq_wr_in[I].data;
    assign sq_valid[I] = sq_wr_in[I].valid;
    assign sq_wr_in[I].ready = sq_wr_out.ready && data_order_iready && cq_order_iready
                            && grant_valid && (grant == W'(I));

    assign d_data[I]  = data_in[I].tdata;
    assign d_keep[I]  = data_in[I].tkeep;
    assign d_tid[I]   = data_in[I].tid;
    assign d_last[I]  = data_in[I].tlast;
    assign d_valid[I] = data_in[I].tvalid;
    assign data_in[I].tready = data_head_valid && (data_head == W'(I)) && data_out.tready;

    assign cq_wr_out[I].data  = cq_wr_in.data;
    assign cq_wr_out[I].valid = cq_wr_in.valid && cq_head_valid && (cq_head == W'(I));
    assign cq_out_ready[I]    = cq_wr_out[I].ready;
end

`ifndef SYNTHESIS
// Every ack on the shared dest must belong to an outstanding granted request.
assert property (@(posedge clk) disable iff (!rst_n)
    !cq_wr_in.valid || cq_head_valid)
else $fatal(1, "StreamWriterPairArbiter received an ack with no outstanding request!");
`endif

`ifdef SYNTHESIS
// Grant machinery and order-FIFO heads. The hang signatures to look for:
// an ack arriving with cq_head_valid low (sim-only assertion above cannot
// fire on hardware — here it shows as probe10 = 2'b10 while probe8[1] = 0),
// a permanently locked grant, or data_head stuck on a writer whose data
// never asserts tlast. Probe widths assume the 2-writer configuration.
if (N_WRITERS == 2) begin : gen_ila
    ila_pair_arbiter inst_ila_pair_arbiter (
        .clk(clk),
        .probe0(rst_n),

        .probe1(sq_valid),
        .probe2({grant_valid, grant_locked, grant_fire}),
        .probe3(grant),
        .probe4(rr),
        .probe5({data_order_iready, cq_order_iready}),
        .probe6({sq_wr_out.valid, sq_wr_out.ready}),

        .probe7({data_head_valid, data_head}),
        .probe8({cq_head_valid, cq_head}),
        .probe9({data_pop, cq_pop}),

        .probe10({cq_wr_in.valid, cq_wr_in.ready}),
        .probe11(cq_out_ready),
        .probe12({data_out.tvalid, data_out.tready, data_out.tlast})
    );
end
`endif

endmodule
