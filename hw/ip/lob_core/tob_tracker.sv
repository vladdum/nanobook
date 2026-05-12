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
// CLZ (M06 D.1–D.3): 2-stage 64×64 hierarchical priority encoder.
//   Stage 1: outer CLZ on slice_present_q[sym][side] (FF, 64 bits).
//   Stage 2: inner CLZ on slice_bitmap_ram[winning slice] (URAM, 64 bits).
// External (TB) kicks via clz_kick / clz_result_* are exercised by
// dv/unit/lob_core/tb_tob_tracker. Internal kicks fire automatically on
// clr-empties-best and drive pending_clr_* for the lob_core orchestrator
// to follow up via update_size_req. Latency: 3 cycles clr → pending_clr_o
// (1 cycle internal kick delay + s1 + s2).
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
    parameter int unsigned SYMBOL_FILTER_ID  = lob_core_params_pkg::SYMBOL_FILTER_ID,
    parameter int unsigned N_SYMBOLS         = lob_core_params_pkg::N_SYMBOLS,
    parameter int unsigned SYM_IDX_W         = lob_core_params_pkg::SYM_IDX_W
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

    // M06: symbol routing index. Selects which per-sym best register to read/update.
    // Default tie-off in lob_core's instantiation is '0 (single-sym mode) until
    // Phase F wires the real value through the orchestrator.
    input  logic [SYM_IDX_W-1:0]       op_sym_idx,

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
    output logic [7:0]        pending_clr_reason_o,
    // M06 F.2 §1: sym_idx of the clr-empties-best emit. Drives lob_core's
    // clr_fu_sym_idx_q latch so the clr_fu1 ladder_read targets the right
    // per-sym slot. Driven from clz_internal_sym_q at the CLZ-result
    // emit cycle (latched on the pending_clr_valid_o pulse).
    output logic [SYM_IDX_W-1:0] pending_clr_sym_idx_o,

    // M06 2-stage CLZ kick interface (D.2). Used by tb_tob_tracker for the
    // pipelined-CLZ correctness tests. D.3 will wire this internally into
    // the emit path; for D.2 these are TB-only outputs.
    input  logic                       clz_kick,
    input  logic [SYM_IDX_W-1:0]       clz_kick_sym,
    input  logic                       clz_kick_side,  // 0=bid (find MSB), 1=ask (find LSB)
    output logic                       clz_result_valid,
    output logic [11:0]                clz_result_tick  // global tick index
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
    // F.2 §6: bid/ask_bitmap_q are kept as debug-only state (Phase H/I
    // integration TBs may probe them) but no longer consumed by the
    // emit decision — that uses per-sym slice_present_q now.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [WINDOW_SIZE_TICKS-1:0] bid_bitmap_q;
    logic [WINDOW_SIZE_TICKS-1:0] ask_bitmap_q;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [IDX_W-1:0]  best_bid_idx_q;
    logic [IDX_W-1:0]  best_ask_idx_q;

    // M06 hierarchical bitmap (D.1).
    // Level 1: slice_present[sym][side][slice] — 1 bit per slice of 64 ticks
    //   Total: N_SYMBOLS × 2 × 64 bits = 16,384 FFs at default. Cheap.
    // Level 2: slice_bitmap[sym][side][slice] — 64-bit bitmap per slice
    //   Total: N_SYMBOLS × 2 × 64 entries × 64 bits = 800 Kbit. URAM-backed.
    //   Access pattern: 1 RMW per set_bit_req / clr_bit_req.
    localparam int unsigned N_SLICES = WINDOW_SIZE_TICKS / 64;   // 64 at default
    // $clog2(1) = 0 which is a zero-width type; floor at 1 so sl is always
    // at least 1 bit wide.  When N_SLICES == 1 the only legal value is 0.
    localparam int unsigned SLICE_W  = (N_SLICES > 1) ? $clog2(N_SLICES) : 1;
    // Address into slice_bitmap_ram: one entry per (sym, side, slice) triple.
    // Total entries = N_SYMBOLS * 2 * N_SLICES; address is $clog2 of that.
    localparam int unsigned SLICE_BITMAP_ADDR_W = $clog2(N_SYMBOLS * 2 * N_SLICES);

    logic [N_SLICES-1:0] slice_present_q [N_SYMBOLS][2];

    /* verilator lint_off UNUSEDPARAM */
    (* ram_style = "ultra" *)
    logic [63:0] slice_bitmap_ram [N_SYMBOLS * 2 * N_SLICES];
    /* verilator lint_on UNUSEDPARAM */

    // M06: per-sym best registers indexed by op_sym_idx.
    /* verilator lint_off UNUSEDSIGNAL */
    // best_*_size_q are part of the spec's tracker state and will be
    // read by lob_core during the EXEC fast-path in Phase H; for the
    // standalone tracker they are only written.
    // best_*_tick_q are likewise tob_tracker state read once Phase F+H
    // threads tob_tracker.op_sym_idx and consumes them on the
    // multi-symbol-aware emit path; until then they are write-only.
    logic [31:0]       best_bid_size_q  [N_SYMBOLS];
    logic [31:0]       best_ask_size_q  [N_SYMBOLS];
    logic [31:0]       best_bid_tick_q  [N_SYMBOLS];
    logic [31:0]       best_ask_tick_q  [N_SYMBOLS];
    /* verilator lint_on UNUSEDSIGNAL */
    logic              best_bid_valid_q [N_SYMBOLS];
    logic              best_ask_valid_q [N_SYMBOLS];

    tob_delta_t delta_q;
    logic       m_tvalid_q;

    // -----------------------------------------------------------------
    // M06 D.3 — CLZ-driven new-best emit state.
    //
    // When clr_bit_req empties the current best level AND the side stays
    // non-empty after the clear, we DO NOT use the M05 flat priority
    // encoder to discover the new best. Instead we kick the 2-stage
    // 64×64 CLZ pipeline (D.1/D.2) one cycle later — by then the NBA
    // updates to slice_present_q / slice_bitmap_ram from the clr cycle
    // have landed, so stage 1 sees the post-clr view.
    //
    // clz_internal_kick_q     — 1-cycle pulse, drives s1 kick next cycle.
    // clz_internal_pending_q  — set on clr-empties-best, cleared when the
    //                           CLZ result emits pending_clr_valid_o.
    // clz_internal_{sym,side,ingress_ts,reason}_q — context latched at
    //                           the clr cycle; replayed into the
    //                           pending_clr_* outputs when the result
    //                           lands ~3 cycles later.
    //
    // best_*_idx_q / best_*_tick_q are deferred to CLZ result time
    // (instead of being updated at the clr cycle). The lob_core
    // orchestrator must avoid issuing new set/clr/upd ops while
    // clz_internal_pending_q is high — Phase F enforces this via
    // per_sym_state's epoch-read stall.
    // -----------------------------------------------------------------
    logic                       clz_internal_kick_q;
    logic                       clz_internal_pending_q;
    logic [SYM_IDX_W-1:0]       clz_internal_sym_q;
    logic                       clz_internal_side_q;
    logic [63:0]                clz_internal_ingress_ts_q;
    logic [7:0]                 clz_internal_reason_q;

    // -----------------------------------------------------------------
    // Combinational helpers. D.3 replaced the M05 flat priority encoders
    // (highest/lowest_set_bit over the 4096-bit bitmap) with the 2-stage
    // 64×64 CLZ pipeline below. F.2 §6 then replaced the global
    // `any_set` side-empty check with a per-sym hierarchical check
    // inlined into the clr branch (post_clr_sp).
    // -----------------------------------------------------------------

    // Bit-reversal helper for CLZ ask-side (find LSB = find MSB of reversed).
    function automatic logic [63:0] reverse64(input logic [63:0] x);
        logic [63:0] r;
        for (int i = 0; i < 64; i++) r[i] = x[63 - i];
        return r;
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
            for (int i = 0; i < N_SYMBOLS; i++) begin
                best_bid_tick_q[i]  <= '0;
                best_bid_size_q[i]  <= '0;
                best_bid_valid_q[i] <= 1'b0;
                best_ask_tick_q[i]  <= '0;
                best_ask_size_q[i]  <= '0;
                best_ask_valid_q[i] <= 1'b0;
            end
            for (int s = 0; s < N_SYMBOLS; s++) begin
                for (int si = 0; si < 2; si++) begin
                    slice_present_q[s][si] <= '0;
                end
            end
            // slice_bitmap_ram doesn't need reset — URAM doesn't init on reset
            // in real silicon. Verilator sim treats unwritten URAM as 0, which
            // matches the slice_present_q='0 invariant: nothing visible until
            // the first set_bit_req.
            delta_q                  <= '0;
            m_tvalid_q               <= 1'b0;
            pending_clr_valid_o      <= 1'b0;
            pending_clr_side_o       <= 1'b0;
            pending_clr_price_o      <= '0;
            pending_clr_ingress_ts_o <= '0;
            pending_clr_reason_o     <= '0;
            pending_clr_sym_idx_o    <= '0;
            clz_internal_kick_q       <= 1'b0;
            clz_internal_pending_q    <= 1'b0;
            clz_internal_sym_q        <= '0;
            clz_internal_side_q       <= 1'b0;
            clz_internal_ingress_ts_q <= '0;
            clz_internal_reason_q     <= '0;
        end else begin
            // Default: deassert m_tvalid each cycle. delta_q is sticky
            // (last-emitted value persists when m_tvalid drops).
            m_tvalid_q          <= 1'b0;
            // pending_clr_valid_o pulses for 1 cycle only.
            pending_clr_valid_o <= 1'b0;
            // Internal CLZ kick pulses for 1 cycle only — it fires the
            // cycle AFTER the clr that triggered it, so the next-cycle
            // s1 read sees the post-NBA slice_present_q.
            clz_internal_kick_q <= 1'b0;

            // D.3 CLZ-result emit: when stage 2 lands AND we have an
            // internal pending (i.e. this result was kicked by an
            // empties-best clr, not a TB-driven external kick), pulse
            // pending_clr_valid_o and update the per-sym best regs.
            //
            // clz_s2_valid_q is set on cycle (kick+2). For our 1-cycle
            // internal kick delay, that's (clr+3). The orchestrator's
            // clr-followup pipeline triggers off pending_clr_valid_o so
            // total clr-to-emit latency increases by ~3 cycles vs M05.
            if (clz_s2_valid_q && clz_internal_pending_q) begin
                pending_clr_valid_o      <= 1'b1;
                pending_clr_side_o       <= clz_internal_side_q;
                pending_clr_price_o      <= 32'(WINDOW_BASE_TICK) + 32'(clz_s2_tick_q);
                pending_clr_ingress_ts_o <= clz_internal_ingress_ts_q;
                pending_clr_reason_o     <= clz_internal_reason_q;
                pending_clr_sym_idx_o    <= clz_internal_sym_q;
                if (clz_internal_side_q == 1'b0) begin
                    best_bid_idx_q                       <= IDX_W'(clz_s2_tick_q);
                    best_bid_tick_q[clz_internal_sym_q]  <= 32'(WINDOW_BASE_TICK) + 32'(clz_s2_tick_q);
                    best_bid_size_q[clz_internal_sym_q]  <= '0;
                    best_bid_valid_q[clz_internal_sym_q] <= 1'b1;
                end else begin
                    best_ask_idx_q                       <= IDX_W'(clz_s2_tick_q);
                    best_ask_tick_q[clz_internal_sym_q]  <= 32'(WINDOW_BASE_TICK) + 32'(clz_s2_tick_q);
                    best_ask_size_q[clz_internal_sym_q]  <= '0;
                    best_ask_valid_q[clz_internal_sym_q] <= 1'b1;
                end
                clz_internal_pending_q <= 1'b0;
            end

            if (set_bit_req) begin
                begin : blk_set_hier
                    logic [SLICE_W-1:0]              sl;
                    logic [5:0]                      bit_in_sl;
                    logic [SLICE_BITMAP_ADDR_W-1:0]  ram_addr;
                    logic [63:0]                     old_slice, new_slice;
                    bit_in_sl = op_idx_w[5:0];
                    // When N_SLICES==1, SLICE_W is clamped to 1 but the only
                    // valid sl value is 0. Mask to ensure no width pollution.
                    sl        = SLICE_W'(op_idx_w >> 6);
                    // Address = (sym_idx * 2 + side) * N_SLICES + sl
                    ram_addr  = SLICE_BITMAP_ADDR_W'(op_sym_idx) * SLICE_BITMAP_ADDR_W'(2 * N_SLICES)
                              + SLICE_BITMAP_ADDR_W'(op_side)    * SLICE_BITMAP_ADDR_W'(N_SLICES)
                              + SLICE_BITMAP_ADDR_W'(sl);
                    old_slice = slice_bitmap_ram[ram_addr];
                    new_slice = old_slice | (64'd1 << bit_in_sl);
                    slice_bitmap_ram[ram_addr]             <= new_slice;
                    slice_present_q[op_sym_idx][op_side][sl] <= 1'b1;
                end
                if (op_side == 1'b0) begin
                    bid_bitmap_q[op_idx_w] <= 1'b1;
                    if (!best_bid_valid_q[op_sym_idx] || op_idx_w > best_bid_idx_q) begin
                        best_bid_idx_q                <= op_idx_w;
                        best_bid_tick_q[op_sym_idx]   <= op_price;
                        best_bid_size_q[op_sym_idx]   <= op_size;
                        best_bid_valid_q[op_sym_idx]  <= 1'b1;
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
                    if (!best_ask_valid_q[op_sym_idx] || op_idx_w < best_ask_idx_q) begin
                        best_ask_idx_q                <= op_idx_w;
                        best_ask_tick_q[op_sym_idx]   <= op_price;
                        best_ask_size_q[op_sym_idx]   <= op_size;
                        best_ask_valid_q[op_sym_idx]  <= 1'b1;
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
            end else if (clr_bit_req) begin : blk_clr_branch
                // M06 F.2 §6: per-sym hierarchical post-clr any-set check
                // replaces the global `any_set(new_bm)` over bid/ask_bitmap_q.
                // post_clr_sp mirrors slice_present_q[sym][side] with the
                // current slice's bit reflecting `new_slice != 0` (the NBA
                // write to slice_present_q lands at the next edge).
                logic [SLICE_W-1:0]              sl;
                logic [5:0]                      bit_in_sl;
                logic [SLICE_BITMAP_ADDR_W-1:0]  ram_addr;
                logic [63:0]                     old_slice, new_slice;
                logic [N_SLICES-1:0]             post_clr_sp;
                logic                            any_set_after_clr_per_sym;

                bit_in_sl = op_idx_w[5:0];
                sl        = SLICE_W'(op_idx_w >> 6);
                ram_addr  = SLICE_BITMAP_ADDR_W'(op_sym_idx) * SLICE_BITMAP_ADDR_W'(2 * N_SLICES)
                          + SLICE_BITMAP_ADDR_W'(op_side)    * SLICE_BITMAP_ADDR_W'(N_SLICES)
                          + SLICE_BITMAP_ADDR_W'(sl);
                old_slice = slice_bitmap_ram[ram_addr];
                new_slice = old_slice & ~(64'd1 << bit_in_sl);
                slice_bitmap_ram[ram_addr]               <= new_slice;
                slice_present_q[op_sym_idx][op_side][sl] <= (new_slice != '0);

                post_clr_sp     = slice_present_q[op_sym_idx][op_side];
                post_clr_sp[sl] = (new_slice != 64'd0);
                any_set_after_clr_per_sym = |post_clr_sp;

                if (op_side == 1'b0) begin
                    // bid_bitmap_q maintained for backwards-compat introspection
                    // (Phase H integration TB may still inspect it). The
                    // emit-decision now uses any_set_after_clr_per_sym, NOT
                    // any_set(bid_bitmap_q).
                    bid_bitmap_q[op_idx_w] <= 1'b0;
                    if (op_idx_w == best_bid_idx_q) begin
                        if (any_set_after_clr_per_sym) begin
                            clz_internal_kick_q       <= 1'b1;
                            clz_internal_pending_q    <= 1'b1;
                            clz_internal_sym_q        <= op_sym_idx;
                            clz_internal_side_q       <= 1'b0;
                            clz_internal_ingress_ts_q <= ingress_ts;
                            clz_internal_reason_q     <= op_reason;
                        end else begin
                            best_bid_valid_q[op_sym_idx]   <= 1'b0;
                            best_bid_tick_q[op_sym_idx]    <= '0;
                            best_bid_size_q[op_sym_idx]    <= '0;
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
                    ask_bitmap_q[op_idx_w] <= 1'b0;
                    if (op_idx_w == best_ask_idx_q) begin
                        if (any_set_after_clr_per_sym) begin
                            clz_internal_kick_q       <= 1'b1;
                            clz_internal_pending_q    <= 1'b1;
                            clz_internal_sym_q        <= op_sym_idx;
                            clz_internal_side_q       <= 1'b1;
                            clz_internal_ingress_ts_q <= ingress_ts;
                            clz_internal_reason_q     <= op_reason;
                        end else begin
                            best_ask_valid_q[op_sym_idx]   <= 1'b0;
                            best_ask_tick_q[op_sym_idx]    <= '0;
                            best_ask_size_q[op_sym_idx]    <= '0;
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
                if (op_side == 1'b0 && best_bid_valid_q[op_sym_idx] &&
                    op_price == 32'(WINDOW_BASE_TICK) + 32'(best_bid_idx_q)) begin
                    best_bid_tick_q[op_sym_idx]   <= op_price;
                    best_bid_size_q[op_sym_idx]   <= op_size;
                    delta_q.ingress_ts     <= ingress_ts;
                    delta_q.emit_ts        <= cur_ts;
                    delta_q.symbol_id      <= 16'(SYMBOL_FILTER_ID);
                    delta_q.side           <= 8'h00;
                    delta_q.reason         <= tob_reason_e'(op_reason);
                    delta_q.new_best_price <= op_price;
                    delta_q.new_best_size  <= op_size;
                    delta_q.flags          <= '0;
                    m_tvalid_q             <= 1'b1;
                end else if (op_side == 1'b1 && best_ask_valid_q[op_sym_idx] &&
                             op_price == 32'(WINDOW_BASE_TICK) + 32'(best_ask_idx_q)) begin
                    best_ask_tick_q[op_sym_idx]   <= op_price;
                    best_ask_size_q[op_sym_idx]   <= op_size;
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

    // -----------------------------------------------------------------
    // M06 D.2 — 2-stage 64×64 pipelined CLZ
    // Stage 1: outer CLZ on slice_present_q[clz_kick_sym][clz_kick_side].
    // Stage 2: inner CLZ on slice_bitmap_ram[winning slice].
    // Latency: kick at cycle K → clz_result_valid at cycle K+2.
    // -----------------------------------------------------------------

    // Stage 1 registers
    logic                       clz_s1_valid_q;
    logic [SYM_IDX_W-1:0]       clz_s1_sym_q;
    logic                       clz_s1_side_q;
    logic [5:0]                 clz_s1_slice_idx_q;
    logic                       clz_s1_any_q;

    // Stage 1 combinational
    logic [63:0]                clz_s1_present;
    logic [63:0]                clz_s1_oriented;
    logic [5:0]                 clz_s1_local;
    logic                       clz_s1_any;

    // D.3 — kick mux: the internal CLZ kick (from clr-empties-best) takes
    // priority over the external TB kick. Both paths feed the same s1
    // latch; the orchestrator must not interleave them (TB kicks are only
    // used by tb_tob_tracker D.2 tests, which never drive set/clr/upd).
    logic                       clz_kick_any;
    logic [SYM_IDX_W-1:0]       clz_kick_sym_any;
    logic                       clz_kick_side_any;
    assign clz_kick_any      = clz_kick || clz_internal_kick_q;
    assign clz_kick_sym_any  = clz_internal_kick_q ? clz_internal_sym_q  : clz_kick_sym;
    assign clz_kick_side_any = clz_internal_kick_q ? clz_internal_side_q : clz_kick_side;

    // Pad slice_present_q to 64 bits for the outer CLZ (N_SLICES may be < 64).
    assign clz_s1_present  = 64'(slice_present_q[clz_kick_sym_any][clz_kick_side_any]);
    assign clz_s1_oriented = (clz_kick_side_any == 1'b0) ? clz_s1_present
                                                          : reverse64(clz_s1_present);
    assign clz_s1_any      = |clz_s1_oriented;

    always_comb begin
        clz_s1_local = 6'd0;
        for (int i = 63; i >= 0; i--) begin
            if (clz_s1_oriented[i]) begin
                clz_s1_local = 6'(i);
                break;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rstn) begin
            clz_s1_valid_q     <= 1'b0;
            clz_s1_sym_q       <= '0;
            clz_s1_side_q      <= 1'b0;
            clz_s1_slice_idx_q <= '0;
            clz_s1_any_q       <= 1'b0;
        end else begin
            clz_s1_valid_q <= clz_kick_any;
            if (clz_kick_any) begin
                clz_s1_sym_q       <= clz_kick_sym_any;
                clz_s1_side_q      <= clz_kick_side_any;
                // For side=0: MSB of present vector is the winning slice.
                // For side=1: oriented is reversed, so bit position in oriented
                // maps to original slice (63 - clz_s1_local) in present.
                clz_s1_slice_idx_q <= (clz_kick_side_any == 1'b0) ? clz_s1_local
                                                                   : (6'd63 - clz_s1_local);
                clz_s1_any_q       <= clz_s1_any;
            end
        end
    end

    // Stage 2 registers
    logic                       clz_s2_valid_q;
    logic [11:0]                clz_s2_tick_q;

    // Stage 2 combinational
    logic [63:0]                clz_s2_slice;
    logic [63:0]                clz_s2_oriented;
    logic [5:0]                 clz_s2_local;

    logic [$clog2(N_SYMBOLS * 2 * N_SLICES)-1:0] clz_s2_ram_addr;
    assign clz_s2_ram_addr = ($clog2(N_SYMBOLS * 2 * N_SLICES))'(clz_s1_sym_q)
                              * ($clog2(N_SYMBOLS * 2 * N_SLICES))'(2 * N_SLICES)
                           + ($clog2(N_SYMBOLS * 2 * N_SLICES))'(clz_s1_side_q)
                              * ($clog2(N_SYMBOLS * 2 * N_SLICES))'(N_SLICES)
                           + ($clog2(N_SYMBOLS * 2 * N_SLICES))'(clz_s1_slice_idx_q);

    assign clz_s2_slice    = (clz_s1_valid_q && clz_s1_any_q)
                             ? slice_bitmap_ram[clz_s2_ram_addr]
                             : 64'd0;
    assign clz_s2_oriented = (clz_s1_side_q == 1'b0) ? clz_s2_slice
                                                      : reverse64(clz_s2_slice);

    always_comb begin
        clz_s2_local = 6'd0;
        for (int i = 63; i >= 0; i--) begin
            if (clz_s2_oriented[i]) begin
                clz_s2_local = 6'(i);
                break;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rstn) begin
            clz_s2_valid_q <= 1'b0;
            clz_s2_tick_q  <= 12'd0;
        end else begin
            clz_s2_valid_q <= clz_s1_valid_q && clz_s1_any_q;
            if (clz_s1_valid_q && clz_s1_any_q) begin : blk_clz_s2_tick
                logic [5:0] bit_natural;
                // For side=0: MSB position in slice is clz_s2_local.
                // For side=1: oriented is reversed, so original bit = 63 - clz_s2_local.
                bit_natural = (clz_s1_side_q == 1'b0) ? clz_s2_local : (6'd63 - clz_s2_local);
                // Global tick = slice_idx * 64 + bit_in_slice
                clz_s2_tick_q <= {clz_s1_slice_idx_q, bit_natural};
            end
        end
    end

    assign clz_result_valid = clz_s2_valid_q;
    assign clz_result_tick  = clz_s2_tick_q;

endmodule : tob_tracker
