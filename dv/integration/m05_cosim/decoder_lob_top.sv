// SPDX-License-Identifier: Apache-2.0
// decoder_lob_top — cosim wrapper that wires itch_decoder.m_* directly to
// lob_core.s_*. Both interfaces are AXI-S of book_event_t (256-bit tdata),
// so the connection is one-to-one with no glue.
//
// Used by dv/integration/m05_cosim/tb_cosim.py to bit-compare the RTL TOB
// stream against sw/refbook (filtered to SYMBOL_FILTER_ID) on the M05 100K
// slice (and, in Phase J, on the full-day captures).

`include "book_event_pkg.sv"

module decoder_lob_top #(
    parameter int unsigned IN_DATA_W  = 64,
    parameter int unsigned EV_DATA_W  = 256,
    parameter int unsigned TS_W       = 48
) (
    input  logic                    clk,
    input  logic                    rstn,

    // Input AXI-S — MoldUDP64-framed ITCH (replay.iter_beats output).
    input  logic [IN_DATA_W-1:0]    s_tdata,
    input  logic [IN_DATA_W/8-1:0]  s_tkeep,
    input  logic                    s_tvalid,
    output logic                    s_tready,
    input  logic                    s_tlast,
    input  logic [TS_W-1:0]         s_tuser,

    // Output AXI-S — tob_delta_t (256-bit) from lob_core.
    output logic [EV_DATA_W-1:0]    m_tdata,
    output logic                    m_tvalid,
    input  logic                    m_tready,
    output logic                    m_tlast,

    // Selected stat counters from both stages (probed by the cosim TB).
    output logic [31:0]             events_emitted,
    output logic [31:0]             slow_path_dropped,
    output logic [31:0]             events_in,
    output logic [31:0]             events_filtered,
    output logic [31:0]             tob_deltas_out
);
    // Inter-module book_event_t bus (256-bit AXI-S between decoder and core).
    logic [EV_DATA_W-1:0] ev_tdata;
    logic                 ev_tvalid;
    logic                 ev_tready;
    logic                 ev_tlast;

    // Decoder stat outputs not surfaced to the TB — drained for Verilator
    // unused-signal lint cleanliness.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] dec_replace_split;
    logic [31:0] dec_mold_seq_gap;
    logic [31:0] dec_frame_malformed;
    logic [7:0]  lob_hash_probe_max;
    logic [31:0] lob_hash_overflow;
    logic [31:0] lob_pool_exhausted;
    logic [31:0] lob_out_of_window;
    logic [31:0] lob_unknown_order;
    logic [31:0] lob_cancel_underflow;
    /* verilator lint_on UNUSEDSIGNAL */

    itch_decoder #(
        .IN_DATA_W (IN_DATA_W),
        .OUT_DATA_W(EV_DATA_W),
        .TS_W      (TS_W)
    ) u_decoder (
        .clk               (clk),
        .rstn              (rstn),
        .s_tdata           (s_tdata),
        .s_tkeep           (s_tkeep),
        .s_tvalid          (s_tvalid),
        .s_tready          (s_tready),
        .s_tlast           (s_tlast),
        .s_tuser           (s_tuser),
        .m_tdata           (ev_tdata),
        .m_tvalid          (ev_tvalid),
        .m_tready          (ev_tready),
        .m_tlast           (ev_tlast),
        .events_emitted    (events_emitted),
        .replace_split     (dec_replace_split),
        .slow_path_dropped (slow_path_dropped),
        .mold_seq_gap      (dec_mold_seq_gap),
        .frame_malformed   (dec_frame_malformed)
    );

    lob_core #(
        .IN_DATA_W (EV_DATA_W),
        .OUT_DATA_W(EV_DATA_W)
    ) u_lob (
        .clk              (clk),
        .rstn             (rstn),
        .s_tdata          (ev_tdata),
        .s_tvalid         (ev_tvalid),
        .s_tready         (ev_tready),
        .s_tlast          (ev_tlast),
        .m_tdata          (m_tdata),
        .m_tvalid         (m_tvalid),
        .m_tready         (m_tready),
        .m_tlast          (m_tlast),
        .events_in        (events_in),
        .events_filtered  (events_filtered),
        .tob_deltas_out   (tob_deltas_out),
        .hash_probe_max   (lob_hash_probe_max),
        .hash_overflow    (lob_hash_overflow),
        .pool_exhausted   (lob_pool_exhausted),
        .out_of_window    (lob_out_of_window),
        .unknown_order    (lob_unknown_order),
        .cancel_underflow (lob_cancel_underflow)
    );

endmodule : decoder_lob_top
