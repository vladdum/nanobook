// SPDX-License-Identifier: Apache-2.0
// itch_decoder — MoldUDP64 + ITCH 5.0 -> book_event_t (M03 RTL).
// Hierarchical 6-stage pipeline; each stage is its own module.
//
// Spec: docs/superpowers/specs/2026-04-26-nanobook-m03-itch-decoder-design.md
// Plan: docs/superpowers/plans/2026-04-26-nanobook-m03-itch-decoder.md

// type_dispatch uses an async negedge-rstn reset; all other stages use
// synchronous reset. Verilator SYNCASYNCNET is expected and suppressed here.
/* verilator lint_off SYNCASYNCNET */
`include "book_event_pkg.sv"

module itch_decoder #(
    parameter int unsigned IN_DATA_W  = 64,
    parameter int unsigned OUT_DATA_W = 256,
    parameter int unsigned TS_W       = 48
) (
    input  logic                  clk,
    input  logic                  rstn,

    // Input AXI-S (post-UDP-strip payload + ingress_ts on TUSER first beat)
    input  logic [IN_DATA_W-1:0]  s_tdata,
    input  logic [IN_DATA_W/8-1:0] s_tkeep,
    input  logic                  s_tvalid,
    output logic                  s_tready,
    input  logic                  s_tlast,
    input  logic [TS_W-1:0]       s_tuser,

    // Output AXI-S (book_event_t)
    output logic [OUT_DATA_W-1:0] m_tdata,
    output logic                  m_tvalid,
    input  logic                  m_tready,
    output logic                  m_tlast,

    // Stat counters (read-only, plumbed to BAR0 in M09)
    output logic [31:0] events_emitted,
    output logic [31:0] replace_split,
    output logic [31:0] slow_path_dropped,
    output logic [31:0] mold_seq_gap,
    output logic [31:0] frame_malformed
);
    import book_event_pkg::*;

    // -----------------------------------------------------------------------
    // Stage 1: mold_strip — strip MoldUDP64 header
    // -----------------------------------------------------------------------
    logic [IN_DATA_W-1:0]   s1_tdata;
    logic [IN_DATA_W/8-1:0] s1_tkeep;
    logic                   s1_tvalid;
    logic                   s1_tready;
    logic                   s1_tlast;
    logic [TS_W-1:0]        s1_tuser;

    mold_strip #(
        .DATA_W(IN_DATA_W),
        .TS_W  (TS_W)
    ) u_mold_strip (
        .clk          (clk),
        .rstn         (rstn),
        .s_tdata      (s_tdata),
        .s_tkeep      (s_tkeep),
        .s_tvalid     (s_tvalid),
        .s_tready     (s_tready),
        .s_tlast      (s_tlast),
        .s_tuser      (s_tuser),
        .m_tdata      (s1_tdata),
        .m_tkeep      (s1_tkeep),
        .m_tvalid     (s1_tvalid),
        .m_tready     (s1_tready),
        .m_tlast      (s1_tlast),
        .m_tuser      (s1_tuser),
        .mold_seq_gap (mold_seq_gap)
    );

    // -----------------------------------------------------------------------
    // Stage 2: msg_boundary — slice into one ITCH message per AXI-S frame
    // -----------------------------------------------------------------------
    logic [IN_DATA_W-1:0]   s2_tdata;
    logic [IN_DATA_W/8-1:0] s2_tkeep;
    logic                   s2_tvalid;
    logic                   s2_tready;
    logic                   s2_tlast;
    logic [TS_W-1:0]        s2_tuser;

    msg_boundary #(
        .DATA_W(IN_DATA_W),
        .TS_W  (TS_W)
    ) u_msg_boundary (
        .clk             (clk),
        .rstn            (rstn),
        .s_tdata         (s1_tdata),
        .s_tkeep         (s1_tkeep),
        .s_tvalid        (s1_tvalid),
        .s_tready        (s1_tready),
        .s_tlast         (s1_tlast),
        .s_tuser         (s1_tuser),
        .m_tdata         (s2_tdata),
        .m_tkeep         (s2_tkeep),
        .m_tvalid        (s2_tvalid),
        .m_tready        (s2_tready),
        .m_tlast         (s2_tlast),
        .m_tuser         (s2_tuser),
        .frame_malformed (frame_malformed)
    );

    // -----------------------------------------------------------------------
    // Stage 3: type_dispatch — route by type byte to 6 output lanes
    // -----------------------------------------------------------------------

    // Five fast-path dispatch lanes (to field_extract)
    logic [IN_DATA_W-1:0]   d_add_tdata,   d_exec_tdata,   d_cancel_tdata,   d_delete_tdata,   d_replace_tdata;
    logic [IN_DATA_W/8-1:0] d_add_tkeep,   d_exec_tkeep,   d_cancel_tkeep,   d_delete_tkeep,   d_replace_tkeep;
    logic                   d_add_tvalid,  d_exec_tvalid,  d_cancel_tvalid,  d_delete_tvalid,  d_replace_tvalid;
    logic                   d_add_tready,  d_exec_tready,  d_cancel_tready,  d_delete_tready,  d_replace_tready;
    logic                   d_add_tlast,   d_exec_tlast,   d_cancel_tlast,   d_delete_tlast,   d_replace_tlast;
    logic [TS_W-1:0]        d_add_tuser,   d_exec_tuser,   d_cancel_tuser,   d_delete_tuser,   d_replace_tuser;

    // Slow-path lane — dropped at M03 (drain immediately)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [IN_DATA_W-1:0]   d_slow_tdata;
    logic [IN_DATA_W/8-1:0] d_slow_tkeep;
    logic [TS_W-1:0]        d_slow_tuser;
    logic                   d_slow_tlast;
    logic                   d_slow_tvalid;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                   d_slow_tready;

    type_dispatch #(
        .DATA_W(IN_DATA_W),
        .TS_W  (TS_W)
    ) u_type_dispatch (
        .clk                    (clk),
        .rstn                   (rstn),
        .s_tdata                (s2_tdata),
        .s_tkeep                (s2_tkeep),
        .s_tvalid               (s2_tvalid),
        .s_tready               (s2_tready),
        .s_tlast                (s2_tlast),
        .s_tuser                (s2_tuser),
        .dispatch_add_tdata     (d_add_tdata),
        .dispatch_add_tkeep     (d_add_tkeep),
        .dispatch_add_tvalid    (d_add_tvalid),
        .dispatch_add_tready    (d_add_tready),
        .dispatch_add_tlast     (d_add_tlast),
        .dispatch_add_tuser     (d_add_tuser),
        .dispatch_exec_tdata    (d_exec_tdata),
        .dispatch_exec_tkeep    (d_exec_tkeep),
        .dispatch_exec_tvalid   (d_exec_tvalid),
        .dispatch_exec_tready   (d_exec_tready),
        .dispatch_exec_tlast    (d_exec_tlast),
        .dispatch_exec_tuser    (d_exec_tuser),
        .dispatch_cancel_tdata  (d_cancel_tdata),
        .dispatch_cancel_tkeep  (d_cancel_tkeep),
        .dispatch_cancel_tvalid (d_cancel_tvalid),
        .dispatch_cancel_tready (d_cancel_tready),
        .dispatch_cancel_tlast  (d_cancel_tlast),
        .dispatch_cancel_tuser  (d_cancel_tuser),
        .dispatch_delete_tdata  (d_delete_tdata),
        .dispatch_delete_tkeep  (d_delete_tkeep),
        .dispatch_delete_tvalid (d_delete_tvalid),
        .dispatch_delete_tready (d_delete_tready),
        .dispatch_delete_tlast  (d_delete_tlast),
        .dispatch_delete_tuser  (d_delete_tuser),
        .dispatch_replace_tdata  (d_replace_tdata),
        .dispatch_replace_tkeep  (d_replace_tkeep),
        .dispatch_replace_tvalid (d_replace_tvalid),
        .dispatch_replace_tready (d_replace_tready),
        .dispatch_replace_tlast  (d_replace_tlast),
        .dispatch_replace_tuser  (d_replace_tuser),
        .dispatch_slow_tdata    (d_slow_tdata),
        .dispatch_slow_tkeep    (d_slow_tkeep),
        .dispatch_slow_tvalid   (d_slow_tvalid),
        .dispatch_slow_tready   (d_slow_tready),
        .dispatch_slow_tlast    (d_slow_tlast),
        .dispatch_slow_tuser    (d_slow_tuser),
        .slow_path_dropped      (slow_path_dropped)
    );

    // Drain slow-path lane immediately (M03: no slow-path processing)
    assign d_slow_tready = 1'b1;

    // -----------------------------------------------------------------------
    // Stage 4: field_extract — 5 per-type extractors, mux to book_event_t
    // -----------------------------------------------------------------------
    book_event_t fe_event;
    logic        fe_valid;
    logic        fe_ready;

    field_extract #(
        .DATA_W(IN_DATA_W),
        .TS_W  (TS_W)
    ) u_field_extract (
        .clk                    (clk),
        .rstn                   (rstn),
        .dispatch_add_tdata     (d_add_tdata),
        .dispatch_add_tkeep     (d_add_tkeep),
        .dispatch_add_tvalid    (d_add_tvalid),
        .dispatch_add_tready    (d_add_tready),
        .dispatch_add_tlast     (d_add_tlast),
        .dispatch_add_tuser     (d_add_tuser),
        .dispatch_exec_tdata    (d_exec_tdata),
        .dispatch_exec_tkeep    (d_exec_tkeep),
        .dispatch_exec_tvalid   (d_exec_tvalid),
        .dispatch_exec_tready   (d_exec_tready),
        .dispatch_exec_tlast    (d_exec_tlast),
        .dispatch_exec_tuser    (d_exec_tuser),
        .dispatch_cancel_tdata  (d_cancel_tdata),
        .dispatch_cancel_tkeep  (d_cancel_tkeep),
        .dispatch_cancel_tvalid (d_cancel_tvalid),
        .dispatch_cancel_tready (d_cancel_tready),
        .dispatch_cancel_tlast  (d_cancel_tlast),
        .dispatch_cancel_tuser  (d_cancel_tuser),
        .dispatch_delete_tdata  (d_delete_tdata),
        .dispatch_delete_tkeep  (d_delete_tkeep),
        .dispatch_delete_tvalid (d_delete_tvalid),
        .dispatch_delete_tready (d_delete_tready),
        .dispatch_delete_tlast  (d_delete_tlast),
        .dispatch_delete_tuser  (d_delete_tuser),
        .dispatch_replace_tdata  (d_replace_tdata),
        .dispatch_replace_tkeep  (d_replace_tkeep),
        .dispatch_replace_tvalid (d_replace_tvalid),
        .dispatch_replace_tready (d_replace_tready),
        .dispatch_replace_tlast  (d_replace_tlast),
        .dispatch_replace_tuser  (d_replace_tuser),
        .m_event                (fe_event),
        .m_valid                (fe_valid),
        .m_ready                (fe_ready),
        .replace_split          (replace_split)
    );

    // -----------------------------------------------------------------------
    // Stage 5: endian_swap — reorder fields to BookEvent.pack() byte order
    // -----------------------------------------------------------------------
    logic [OUT_DATA_W-1:0] es_event;
    logic                  es_valid;
    logic                  es_ready;

    endian_swap #(
        .EVENT_W(OUT_DATA_W)
    ) u_endian_swap (
        .clk     (clk),
        .rstn    (rstn),
        .s_event (fe_event),
        .s_valid (fe_valid),
        .s_ready (fe_ready),
        .m_event (es_event),
        .m_valid (es_valid),
        .m_ready (es_ready)
    );

    // -----------------------------------------------------------------------
    // Stage 6: event_pack — registered AXI-S output
    // -----------------------------------------------------------------------
    event_pack #(
        .DATA_W(OUT_DATA_W)
    ) u_event_pack (
        .clk      (clk),
        .rstn     (rstn),
        .s_event  (es_event),
        .s_valid  (es_valid),
        .s_ready  (es_ready),
        .m_tdata  (m_tdata),
        .m_tvalid (m_tvalid),
        .m_tready (m_tready),
        .m_tlast  (m_tlast)
    );

    // -----------------------------------------------------------------------
    // events_emitted counter — count each output beat accepted
    // -----------------------------------------------------------------------
    logic [31:0] events_emitted_q;
    assign events_emitted = events_emitted_q;

    always_ff @(posedge clk) begin
        if (!rstn) begin
            events_emitted_q <= '0;
        end else begin
            if (m_tvalid && m_tready)
                events_emitted_q <= events_emitted_q + 32'd1;
        end
    end

endmodule
