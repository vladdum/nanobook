// SPDX-License-Identifier: Apache-2.0
// tob_tracker — bitmap + best-of-side regs + 1-stage CLZ + tob_delta_t emit.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//       §3.1, §3.2 step 4, §3.3 step 5, §5.1.
// Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 20.
//
// State:
//   - 2 x WINDOW_SIZE_TICKS-bit bitmaps (bid / ask). Intentionally NOT URAM —
//     too small for URAM packing, lives in flops/distRAM.
//   - best_{bid,ask}_idx_q / best_{bid,ask}_size_q / best_{bid,ask}_valid_q.
//
// CLZ: 1-stage flat priority encoder (combinational `for` loop with `break`).
// M06 will pipeline this into a 64x64 CLZ for performance — for M05 the
// 4096-bit flat encoder closes timing per the spec §3.1 budget.
//
// Output: 256-bit AXI-S beat carrying tob_delta_t whenever best changes
// (price OR size). m_tvalid_q is registered, asserts for one cycle per emit.
//
// On level-empty CLZ recomputation new_best_size is emitted as 0; the
// standalone tracker has no per-tick size table, so lob_core fills it
// in on the following cycle from price_ladder (spec §3.3 step 5). This is
// a TB-visible behaviour — see dv/unit/lob_core/tb_tob_tracker.py.

`include "book_event_pkg.sv"

// Note: lob_core_params_pkg.sv is intentionally NOT `\`included` here —
// the simulation/lint flow lists it directly in the source list, and a
// double declaration would trip Verilator's MODDUP warning.

// Module-level parameters share names with the package they default to;
// VARHIDDEN waivers cover the deliberate shadowing for parameter override.
/* verilator lint_off VARHIDDEN */
/* verilator lint_off UNUSEDPARAM */
module tob_tracker
  import book_event_pkg::*;
#(
    parameter int unsigned WINDOW_BASE_TICK  = lob_core_params_pkg::WINDOW_BASE_TICK,
    parameter int unsigned WINDOW_SIZE_TICKS = lob_core_params_pkg::WINDOW_SIZE_TICKS,
    parameter int unsigned SYMBOL_FILTER_ID  = lob_core_params_pkg::SYMBOL_FILTER_ID
) (
/* verilator lint_on VARHIDDEN */
/* verilator lint_on UNUSEDPARAM */
    input  logic              clk,
    input  logic              rstn,

    // From price_ladder
    input  logic              set_bit_req,
    input  logic              clr_bit_req,
    input  logic              update_size_req,
    input  logic              op_side,
    input  logic [31:0]       op_price,
    input  logic [31:0]       op_size,
    // op_reason is the originating event type (TOB_REASON_*). lob_core
    // forwards the ITCH event type so the emitted tob_delta carries the
    // same reason refbook would emit (refbook stamps each delta with the
    // event that caused it). Branches below use this in place of the
    // M05-Phase-G hardcoded ADD/DELETE/EXEC values.
    input  logic [7:0]        op_reason,

    // Wall-clock for emit_ts (driven by lob_core or upstream counter)
    input  logic [63:0]       cur_ts,
    input  logic [63:0]       ingress_ts,

    // tob_delta_t output AXI-S
    output logic [255:0]      m_tdata,
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic              m_tlast,

    // Pending-clr-emit signalling. When clr_bit_req empties the current
    // best AND a new best exists (via CLZ on the post-clr bitmap),
    // tob_tracker DOES NOT emit a placeholder delta on m_tvalid; instead
    // it pulses pending_clr_valid_o for one cycle with the new best's
    // coordinates. lob_core observes this pulse, reads the new best's
    // size from price_ladder, and drives update_size_req with the
    // correct size — that's the cycle the actual delta gets emitted.
    // For clr_bit_req that empties the side entirely (no new best),
    // tob_tracker emits the side-empty delta directly (size=0 is right).
    output logic              pending_clr_valid_o,
    output logic              pending_clr_side_o,
    output logic [31:0]       pending_clr_price_o,
    output logic [63:0]       pending_clr_ingress_ts_o,
    output logic [7:0]        pending_clr_reason_o
);
    localparam int unsigned IDX_W = $clog2(WINDOW_SIZE_TICKS);

    // -----------------------------------------------------------------
    // Sibling-module parameter touch.
    //
    // POOL_SLOTS, HASH_SLOTS, MAX_PROBE_DEPTH and HASH_FN belong to
    // sibling modules (order_pool, order_id_hash, lob_core);
    // tob_tracker does not read them. The window / symbol params are
    // pulled via the module's own overridable parameters, so under
    // -GWINDOW_BASE_TICK the lint flow drops the package values as
    // orphaned. Touching all seven as localparams keeps the
    // standalone lint clean. The UNUSEDPARAM waiver below covers the
    // touch.
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned _PKG_WINDOW_BASE_TICK   =
        lob_core_params_pkg::WINDOW_BASE_TICK;
    localparam int unsigned _PKG_WINDOW_SIZE_TICKS  =
        lob_core_params_pkg::WINDOW_SIZE_TICKS;
    localparam int unsigned _PKG_SYMBOL_FILTER_ID   =
        lob_core_params_pkg::SYMBOL_FILTER_ID;
    localparam int unsigned _PKG_POOL_SLOTS         =
        lob_core_params_pkg::POOL_SLOTS;
    localparam int unsigned _PKG_HASH_SLOTS         =
        lob_core_params_pkg::HASH_SLOTS;
    localparam int unsigned _PKG_MAX_PROBE_DEPTH    =
        lob_core_params_pkg::MAX_PROBE_DEPTH;
    localparam lob_core_params_pkg::hash_fn_e _PKG_HASH_FN =
        lob_core_params_pkg::HASH_FN;
    /* verilator lint_on UNUSEDPARAM */

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------
    logic [WINDOW_SIZE_TICKS-1:0] bid_bitmap_q;
    logic [WINDOW_SIZE_TICKS-1:0] ask_bitmap_q;

    logic [IDX_W-1:0]  best_bid_idx_q;
    logic [IDX_W-1:0]  best_ask_idx_q;
    /* verilator lint_off UNUSEDSIGNAL */
    // best_*_size_q are part of the spec's tracker state and will be
    // read by lob_core during the EXEC fast-path in Phase H; for the
    // standalone tracker they are only written.
    logic [31:0]       best_bid_size_q;
    logic [31:0]       best_ask_size_q;
    /* verilator lint_on UNUSEDSIGNAL */
    logic              best_bid_valid_q;
    logic              best_ask_valid_q;

    tob_delta_t delta_q;
    logic       m_tvalid_q;

    // -----------------------------------------------------------------
    // Combinational helpers — 1-stage flat priority encoders.
    // -----------------------------------------------------------------
    function automatic logic [IDX_W-1:0] highest_set_bit
        (input logic [WINDOW_SIZE_TICKS-1:0] v);
        logic [IDX_W-1:0] r;
        r = '0;
        for (int i = WINDOW_SIZE_TICKS - 1; i >= 0; i--) begin
            if (v[i]) begin
                r = IDX_W'(i);
                break;
            end
        end
        return r;
    endfunction

    function automatic logic [IDX_W-1:0] lowest_set_bit
        (input logic [WINDOW_SIZE_TICKS-1:0] v);
        logic [IDX_W-1:0] r;
        r = '0;
        for (int i = 0; i < WINDOW_SIZE_TICKS; i++) begin
            if (v[i]) begin
                r = IDX_W'(i);
                break;
            end
        end
        return r;
    endfunction

    function automatic logic any_set(input logic [WINDOW_SIZE_TICKS-1:0] v);
        return |v;
    endfunction

    // -----------------------------------------------------------------
    // Output wiring — remap delta_q (SV-packed: first field at MSB)
    // into the C++ TobDelta little-endian byte layout that the host
    // and the refbook consume. This mirrors hw/ip/itch_decoder/
    // endian_swap.sv for book_event_t.
    //
    // tob_delta_t SV-packed layout (first field at MSB):
    //   [255:192] ingress_ts (64)
    //   [191:128] emit_ts    (64)
    //   [127:112] symbol_id  (16)
    //   [111:104] side       (8)
    //   [103:96]  reason     (8)
    //   [95:64]   new_best_price (32)
    //   [63:32]   new_best_size  (32)
    //   [31:0]    flags          (32)
    //
    // Target C++ layout (sw/refbook tob_delta.h, struct.unpack
    // "<QQHBBIII"):
    //   bytes  0..7 : ingress_ts LE
    //   bytes  8..15: emit_ts    LE
    //   bytes 16..17: symbol_id  LE
    //   byte  18    : side
    //   byte  19    : reason
    //   bytes 20..23: new_best_price LE
    //   bytes 24..27: new_best_size  LE
    //   bytes 28..31: flags          LE
    logic [255:0] m_tdata_w;
    always_comb begin
        m_tdata_w           = '0;
        m_tdata_w[63:0]     = delta_q.ingress_ts;
        m_tdata_w[127:64]   = delta_q.emit_ts;
        m_tdata_w[143:128]  = delta_q.symbol_id;
        m_tdata_w[151:144]  = delta_q.side;
        m_tdata_w[159:152]  = delta_q.reason;
        m_tdata_w[191:160]  = delta_q.new_best_price;
        m_tdata_w[223:192]  = delta_q.new_best_size;
        m_tdata_w[255:224]  = delta_q.flags;
    end

    assign m_tdata  = m_tdata_w;
    assign m_tvalid = m_tvalid_q;
    assign m_tlast  = m_tvalid_q;

    // m_tready is part of the AXI-S contract but the M05 consumer
    // (lob_core orchestrator + downstream FIFO) is always-ready by
    // design; tob_tracker emits a single beat per event so we don't
    // back-pressure here. Keep the input wired for lint cleanliness.
    logic _unused_mready;
    assign _unused_mready = m_tready;

    // -----------------------------------------------------------------
    // Datapath
    // -----------------------------------------------------------------
    // Compute the bitmap index up front so the slice happens on a
    // named net (Verilator rejects bit-selects on parenthesised
    // expressions). Upper bits of op_price_offset_w are intentionally
    // dropped — out-of-window prices are filtered by lob_core before
    // they ever reach this module.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]      op_price_offset_w;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [IDX_W-1:0] op_idx_w;
    assign op_price_offset_w = op_price - 32'(WINDOW_BASE_TICK);
    assign op_idx_w          = op_price_offset_w[IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (!rstn) begin
            bid_bitmap_q     <= '0;
            ask_bitmap_q     <= '0;
            best_bid_idx_q   <= '0;
            best_ask_idx_q   <= '0;
            best_bid_size_q  <= '0;
            best_ask_size_q  <= '0;
            best_bid_valid_q <= 1'b0;
            best_ask_valid_q <= 1'b0;
            delta_q                  <= '0;
            m_tvalid_q               <= 1'b0;
            pending_clr_valid_o      <= 1'b0;
            pending_clr_side_o       <= 1'b0;
            pending_clr_price_o      <= '0;
            pending_clr_ingress_ts_o <= '0;
            pending_clr_reason_o     <= '0;
        end else begin
            // Default: deassert m_tvalid each cycle. delta_q is sticky
            // (last-emitted value persists when m_tvalid drops).
            m_tvalid_q          <= 1'b0;
            // pending_clr_valid_o pulses for 1 cycle only.
            pending_clr_valid_o <= 1'b0;

            if (set_bit_req) begin
                if (op_side == 1'b0) begin
                    bid_bitmap_q[op_idx_w] <= 1'b1;
                    if (!best_bid_valid_q || op_idx_w > best_bid_idx_q) begin
                        best_bid_idx_q   <= op_idx_w;
                        best_bid_size_q  <= op_size;
                        best_bid_valid_q <= 1'b1;
                        delta_q.ingress_ts     <= ingress_ts;
                        delta_q.emit_ts        <= cur_ts;
                        delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                        delta_q.side           <= 8'h00;
                        delta_q.reason         <= tob_reason_e'(op_reason);
                        delta_q.new_best_price <= op_price;
                        delta_q.new_best_size  <= op_size;
                        delta_q.flags          <= '0;
                        m_tvalid_q             <= 1'b1;
                    end
                end else begin
                    ask_bitmap_q[op_idx_w] <= 1'b1;
                    if (!best_ask_valid_q || op_idx_w < best_ask_idx_q) begin
                        best_ask_idx_q   <= op_idx_w;
                        best_ask_size_q  <= op_size;
                        best_ask_valid_q <= 1'b1;
                        delta_q.ingress_ts     <= ingress_ts;
                        delta_q.emit_ts        <= cur_ts;
                        delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                        delta_q.side           <= 8'h01;
                        delta_q.reason         <= tob_reason_e'(op_reason);
                        delta_q.new_best_price <= op_price;
                        delta_q.new_best_size  <= op_size;
                        delta_q.flags          <= '0;
                        m_tvalid_q             <= 1'b1;
                    end
                end
            end else if (clr_bit_req) begin
                if (op_side == 1'b0) begin
                    logic [WINDOW_SIZE_TICKS-1:0] new_bm;
                    new_bm           = bid_bitmap_q;
                    new_bm[op_idx_w] = 1'b0;
                    bid_bitmap_q     <= new_bm;
                    if (op_idx_w == best_bid_idx_q) begin
                        if (any_set(new_bm)) begin
                            logic [IDX_W-1:0] nb;
                            nb = highest_set_bit(new_bm);
                            best_bid_idx_q  <= nb;
                            best_bid_size_q <= '0;
                            // Defer the actual emit. lob_core will fetch
                            // the new best's size via price_ladder and
                            // drive update_size_req with the correct
                            // value next-next cycle.
                            pending_clr_valid_o      <= 1'b1;
                            pending_clr_side_o       <= 1'b0;
                            pending_clr_price_o      <= 32'(WINDOW_BASE_TICK) + 32'(nb);
                            pending_clr_ingress_ts_o <= ingress_ts;
                            pending_clr_reason_o     <= op_reason;
                            // m_tvalid_q stays low here.
                        end else begin
                            best_bid_valid_q       <= 1'b0;
                            best_bid_size_q        <= '0;
                            delta_q.new_best_price <= '0;
                            delta_q.new_best_size  <= '0;
                            delta_q.ingress_ts     <= ingress_ts;
                            delta_q.emit_ts        <= cur_ts;
                            delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                            delta_q.side           <= 8'h00;
                            delta_q.reason         <= tob_reason_e'(op_reason);
                            delta_q.flags          <= '0;
                            m_tvalid_q             <= 1'b1;
                        end
                    end
                end else begin
                    logic [WINDOW_SIZE_TICKS-1:0] new_bm;
                    new_bm           = ask_bitmap_q;
                    new_bm[op_idx_w] = 1'b0;
                    ask_bitmap_q     <= new_bm;
                    if (op_idx_w == best_ask_idx_q) begin
                        if (any_set(new_bm)) begin
                            logic [IDX_W-1:0] nb;
                            nb = lowest_set_bit(new_bm);
                            best_ask_idx_q  <= nb;
                            best_ask_size_q <= '0;
                            pending_clr_valid_o      <= 1'b1;
                            pending_clr_side_o       <= 1'b1;
                            pending_clr_price_o      <= 32'(WINDOW_BASE_TICK) + 32'(nb);
                            pending_clr_ingress_ts_o <= ingress_ts;
                            pending_clr_reason_o     <= op_reason;
                        end else begin
                            best_ask_valid_q       <= 1'b0;
                            best_ask_size_q        <= '0;
                            delta_q.new_best_price <= '0;
                            delta_q.new_best_size  <= '0;
                            delta_q.ingress_ts     <= ingress_ts;
                            delta_q.emit_ts        <= cur_ts;
                            delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                            delta_q.side           <= 8'h01;
                            delta_q.reason         <= tob_reason_e'(op_reason);
                            delta_q.flags          <= '0;
                            m_tvalid_q             <= 1'b1;
                        end
                    end
                end
            end else if (update_size_req) begin
                // Size-only change at the current best (EXEC didn't
                // zero out the level). Only emits if the price matches
                // the current best — non-best size changes don't emit.
                if (op_side == 1'b0 && best_bid_valid_q &&
                    op_price == 32'(WINDOW_BASE_TICK) + 32'(best_bid_idx_q)) begin
                    best_bid_size_q        <= op_size;
                    delta_q.ingress_ts     <= ingress_ts;
                    delta_q.emit_ts        <= cur_ts;
                    delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                    delta_q.side           <= 8'h00;
                    delta_q.reason         <= tob_reason_e'(op_reason);
                    delta_q.new_best_price <= op_price;
                    delta_q.new_best_size  <= op_size;
                    delta_q.flags          <= '0;
                    m_tvalid_q             <= 1'b1;
                end else if (op_side == 1'b1 && best_ask_valid_q &&
                             op_price == 32'(WINDOW_BASE_TICK) + 32'(best_ask_idx_q)) begin
                    best_ask_size_q        <= op_size;
                    delta_q.ingress_ts     <= ingress_ts;
                    delta_q.emit_ts        <= cur_ts;
                    delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                    delta_q.side           <= 8'h01;
                    delta_q.reason         <= tob_reason_e'(op_reason);
                    delta_q.new_best_price <= op_price;
                    delta_q.new_best_size  <= op_size;
                    delta_q.flags          <= '0;
                    m_tvalid_q             <= 1'b1;
                end
            end
        end
    end

endmodule : tob_tracker
