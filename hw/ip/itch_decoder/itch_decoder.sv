// SPDX-License-Identifier: Apache-2.0
// itch_decoder — MoldUDP64 + ITCH 5.0 -> book_event_t (M03 RTL).
// Hierarchical 6-stage pipeline; each stage is its own module.
//
// Spec: docs/superpowers/specs/2026-04-26-nanobook-m03-itch-decoder-design.md
// Plan: docs/superpowers/plans/2026-04-26-nanobook-m03-itch-decoder.md

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

    // Stub: tie everything to safe defaults until the real stages land.
    assign s_tready          = 1'b1;
    assign m_tdata           = '0;
    assign m_tvalid          = 1'b0;
    assign m_tlast           = 1'b0;
    assign events_emitted    = '0;
    assign replace_split     = '0;
    assign slow_path_dropped = '0;
    assign mold_seq_gap      = '0;
    assign frame_malformed   = '0;

    // Reference unused inputs to suppress lint warnings until stages wire them.
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0, s_tdata, s_tkeep, s_tvalid, s_tlast, s_tuser, m_tready, rstn, clk};
    /* verilator lint_on UNUSED */

endmodule
