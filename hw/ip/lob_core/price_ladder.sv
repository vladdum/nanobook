// SPDX-License-Identifier: Apache-2.0
// price_ladder — per-tick {head, tail, agg_size, count} state in URAM.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (top-level dataflow), §3.2 step 4-6 (ADD), §3.3 step 3-4 (DELETE),
//   §5.1 (memory architecture), §6 (cycle targets).
//
// One row per (side, tick_offset) holds the price-level head/tail slot
// pointers, aggregate size, and order count. A 1-deep bypass register
// forwards a previous-cycle writeback onto a same-address read; an
// in-flight forwarding mux covers the back-to-back-on-same-address hazard
// where stage 1 commits a write the very cycle stage 0 issues a read on
// that address. Both paths together satisfy spec §3.2's correctness
// requirement under the post-2026-05-13 2-stage pipeline.
//
// 2026-05-13 amendment — registered URAM read:
//   Pre-amendment the level URAM was read combinationally inside an
//   always_ff (read_level() called in the same cycle as the writeback).
//   Vivado therefore could not infer URAM/BRAM and the `levels` array
//   fell back to flip-flops (393K FFs at the smoke config @ N_SYMBOLS=4
//   — three orders of magnitude too many at production sizing). The
//   M06 Phase J OOC synth attempt was killed by that synthesis cost.
//
//   The amended module pipelines into two stages so the URAM read is a
//   true synchronous URAM read:
//     - Stage 0 (input cycle): compute `a_d = addr_of(...)` and
//       `in_win_d = in_window_with_origin(...)` combinationally. Latch
//       op metadata into s1_*_q registers and issue the URAM read
//       (s1_cur_q <= read_level_d(a_d)). read_level_d combinationally
//       muxes between the URAM array, the bypass register (1-cycle-old
//       write), and the in-flight forward (write committing this cycle
//       from stage 1).
//     - Stage 1 (commit cycle): use s1_*_q to compute `nxt`, write
//       levels[s1_addr_q] <= nxt, update the bypass register, and emit
//       the level_evt_* pulse + the read_head/tail/agg_size/count
//       registers.
//
//   Latency consequence (spec §6): ADD, DEL, and read each +1 cycle.
//
// Bound check: ops outside [op_origin, op_origin + WINDOW_SIZE_TICKS)
// are silently refused and bump the `out_of_window` saturating counter.
//
// Standalone parameterised: this module does NOT import lob_core_params_pkg
// — WINDOW_BASE_TICK / WINDOW_SIZE_TICKS / SLOT_IDX_W are passed as
// parameters, mirroring order_pool.sv. The orchestrator (Phase H) wires
// the package values in at instantiation time.
//
// Token reference to lob_core_params_pkg is provided below so the
// verification lint command (which puts the package on the same cmdline)
// does not flag UNUSEDPARAM on the package symbols this module deliberately
// does not consume — those symbols are consumed by sibling sub-modules.

module price_ladder
  import lob_core_params_pkg::*;
#(
    parameter int unsigned PKG_WINDOW_BASE_TICK  = lob_core_params_pkg::WINDOW_BASE_TICK,
    parameter int unsigned PKG_WINDOW_SIZE_TICKS = lob_core_params_pkg::WINDOW_SIZE_TICKS,
    parameter int unsigned PKG_SYMBOL_FILTER_ID  = lob_core_params_pkg::SYMBOL_FILTER_ID,
    parameter int unsigned PKG_POOL_SLOTS        = lob_core_params_pkg::POOL_SLOTS,
    parameter int unsigned PKG_HASH_SLOTS        = lob_core_params_pkg::HASH_SLOTS,
    parameter int unsigned PKG_MAX_PROBE_DEPTH   = lob_core_params_pkg::MAX_PROBE_DEPTH,
    parameter hash_fn_e    PKG_HASH_FN           = lob_core_params_pkg::HASH_FN,
    /* verilator lint_off VARHIDDEN */
    parameter int unsigned WINDOW_BASE_TICK      = PKG_WINDOW_BASE_TICK,
    parameter int unsigned WINDOW_SIZE_TICKS     = PKG_WINDOW_SIZE_TICKS,
    parameter int unsigned N_SYMBOLS             = lob_core_params_pkg::N_SYMBOLS,
    /* verilator lint_on VARHIDDEN */
    parameter int unsigned SLOT_IDX_W            = 24
) (
    input  logic                       clk,
    input  logic                       rstn,

    // Operation interface (one-hot req)
    input  logic                       add_req,
    input  logic                       del_req,
    input  logic                       read_req,
    input  logic                       op_side,        // 0=bid, 1=ask
    input  logic [31:0]                op_price,       // absolute tick (NOT offset)
    input  logic [SLOT_IDX_W-1:0]      op_slot,
    input  logic [31:0]                op_shares,
    // op_partial: when high alongside del_req, decrements only agg_size
    // (NOT count, head, tail). Models a partial cancel/exec of one
    // order at this level — the order itself stays alive in the linked
    // list. Default 0 (full removal of one order). Only meaningful with
    // del_req.
    input  logic                       op_partial,

    // Read outputs are valid 2 cycles after read_req asserts (post
    // 2026-05-13 amendment: 1 input-capture cycle + 1 URAM-read cycle).
    output logic [SLOT_IDX_W-1:0]      read_head,
    output logic [SLOT_IDX_W-1:0]      read_tail,
    output logic [31:0]                read_agg_size,
    output logic [15:0]                read_count,

    // For lob_core: report the new tail's prev pointer = the old tail.
    output logic [SLOT_IDX_W-1:0]      add_old_tail,

    // For tob_tracker: bitmap delta + level transition notification.
    // level_evt_size is the POST-op aggregate for the affected level —
    // for ADD-creates-level it's op_shares, for DEL-empties-level it's 0.
    // Coincident with level_evt_valid; lob_core forwards it to tob_tracker
    // as op_size so the emitted tob_delta carries the correct new_best_size.
    output logic                       level_now_empty,
    output logic                       level_now_active,
    output logic                       level_evt_valid,
    output logic                       level_evt_side,
    output logic [31:0]                level_evt_price,
    output logic [31:0]                level_evt_size,
    // M06 F.2 §1: forward op_sym_idx alongside the other level_evt_*
    // fields so the orchestrator (and ultimately tob_tracker) knows
    // which sym the pulse refers to. Registered on the same cycle as
    // level_evt_valid.
    output logic [SYM_IDX_W-1:0]       level_evt_sym_idx,

    // M06: symbol routing index. Defaults to '0 in the M05 single-symbol
    // lob_core instantiation (Phase F will wire the real per-symbol value).
    input  logic [SYM_IDX_W-1:0]       op_sym_idx,

    // M06 F.2 §2: per-sym ladder origin. `addr_of` and `in_window` use this
    // instead of the static WINDOW_BASE_TICK, so multi-symbol ops route to
    // their own per-sym URAM slot and OOW detection follows the per-sym
    // sliding window. Defaults to WINDOW_BASE_TICK when lob_core ties off
    // (back-compat with the M05 single-symbol smoke / cycles TBs).
    input  logic [31:0]                op_origin,

    output logic [31:0]                out_of_window
);
    localparam int unsigned OFFS_W = $clog2(WINDOW_SIZE_TICKS);
    localparam int unsigned ADDR_W = SYM_IDX_W + OFFS_W + 1;  // sym + side + offset

    typedef struct packed {
        logic [SLOT_IDX_W-1:0] head;
        logic [SLOT_IDX_W-1:0] tail;
        logic [31:0]           agg_size;
        logic [15:0]           count;
    } level_t;

    // NOTE: N_SYMBOLS * 2 * WINDOW_SIZE_TICKS * 96-b ≈ 100 Mbit at default
    // sizes — Verilator simulation handles this fine, but Vivado OOC synth
    // (Phase J) uses parameter overrides to reduce to spec-comparable smoke
    // sizes. Post 2026-05-13 amendment, the URAM read is registered into
    // s1_cur_q via the pipeline below, so Vivado infers UltraRAM
    // (ram_style="ultra") cleanly.
    /* verilator lint_off UNUSEDPARAM */
    (* ram_style = "ultra" *)
    level_t levels [N_SYMBOLS * 2 * WINDOW_SIZE_TICKS];
    /* verilator lint_on UNUSEDPARAM */

    logic [31:0] out_of_window_q;
    assign out_of_window = out_of_window_q;

    // Bypass register for the 1-cycle-stale write→read hazard. Captures
    // stage 1's write at the same NBA edge the write goes to levels[]; the
    // next cycle's stage-0 read consults this register before falling
    // through to the URAM read. Together with the in-flight forwarding
    // mux below this covers spec §3.2's correctness requirement.
    logic               bypass_valid_q;
    logic [ADDR_W-1:0]  bypass_addr_q;
    level_t             bypass_data_q;

    // F.2 §2: both helpers now derive the offset / bounds from the per-op
    // origin (lob_core forwards pss_read_origin for ADD/read paths and
    // d3_pl_q.read_origin for DEL — both threaded via the `op_origin`
    // port). Single-symbol callers tie `op_origin = WINDOW_BASE_TICK` and
    // recover the M05 behaviour.
    function automatic logic in_window_with_origin(input logic [31:0] p,
                                                    input logic [31:0] origin);
        return (p >= origin) && (p < (origin + WINDOW_SIZE_TICKS));
    endfunction

    function automatic logic [ADDR_W-1:0] addr_of(input logic [SYM_IDX_W-1:0] sym,
                                                   input logic side,
                                                   input logic [31:0] p,
                                                   input logic [31:0] origin);
        logic [OFFS_W-1:0] offs;
        offs = OFFS_W'(p - origin);
        return {sym, side, offs};
    endfunction

    // ----------------------------------------------------------------------
    // Stage-1 pipeline registers — capture op metadata + the URAM read.
    // ----------------------------------------------------------------------
    logic                       s1_add_q, s1_del_q, s1_read_q;
    logic                       s1_side_q, s1_partial_q;
    logic [31:0]                s1_price_q, s1_shares_q;
    logic [SLOT_IDX_W-1:0]      s1_slot_q;
    logic [SYM_IDX_W-1:0]       s1_sym_idx_q;
    logic [ADDR_W-1:0]          s1_addr_q;
    logic                       s1_in_window_q;
    level_t                     s1_cur_q;

    // Combinational stage-0 helpers.
    logic [ADDR_W-1:0]          a_d;
    logic                       in_win_d;
    always_comb begin
        a_d      = addr_of(op_sym_idx, op_side, op_price, op_origin);
        in_win_d = in_window_with_origin(op_price, op_origin);
    end

    // Combinational stage-1 nxt + write-enable. These feed both the actual
    // writeback (registered) and the in-flight forwarding mux (so a
    // back-to-back ADD/ADD or ADD/DEL on the same address resolves
    // correctly even though the bypass register isn't updated until the
    // NBA at the end of this cycle).
    level_t s1_nxt_d;
    logic   s1_writing_d;
    always_comb begin
        s1_nxt_d     = '0;
        s1_writing_d = 1'b0;
        if (s1_add_q && s1_in_window_q) begin
            s1_writing_d        = 1'b1;
            s1_nxt_d.tail       = s1_slot_q;
            s1_nxt_d.agg_size   = s1_cur_q.agg_size + s1_shares_q;
            s1_nxt_d.count      = s1_cur_q.count + 16'd1;
            s1_nxt_d.head       = (s1_cur_q.count == 16'd0) ? s1_slot_q : s1_cur_q.head;
        end else if (s1_del_q && s1_in_window_q) begin
            s1_writing_d        = 1'b1;
            s1_nxt_d            = s1_cur_q;
            s1_nxt_d.agg_size   = s1_cur_q.agg_size - s1_shares_q;
            if (!s1_partial_q) begin
                s1_nxt_d.count  = s1_cur_q.count - 16'd1;
            end
        end
    end

    // Stage-0 URAM read with forwarding. The read returns:
    //   1. s1_nxt_d if stage 1 is committing a write to the same address
    //      this cycle (covers back-to-back same-address ops, where the
    //      bypass register's NBA hasn't fired yet);
    //   2. bypass_data_q if the previous cycle's stage-1 write was to the
    //      same address (covers 1-cycle-spaced same-address ops);
    //   3. levels[a] otherwise (the URAM read).
    //
    // Vivado: this expression is folded into the URAM sync-read pattern
    // because the result drives s1_cur_q via NBA in the always_ff below.
    // The combinational forwarding muxes appear AFTER the URAM output
    // register in the synthesised graph, so the URAM cell is inferred
    // cleanly and the (* ram_style = "ultra" *) hint is honoured.
    function automatic level_t read_level_d(input logic [ADDR_W-1:0] a);
        if (s1_writing_d && (s1_addr_q == a))            return s1_nxt_d;
        if (bypass_valid_q && (bypass_addr_q == a))      return bypass_data_q;
        return levels[a];
    endfunction

    // ----------------------------------------------------------------------
    // Sequential pipeline.
    //   Stage 0 (always-on): latch op metadata + URAM read into s1_*_q.
    //   Stage 1 (gated on s1_*_q): commit write, emit pulses, update outs.
    //   Bypass register and out_of_window counter update at stage 1.
    // ----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rstn) begin
            // Pipeline regs
            s1_add_q        <= 1'b0;
            s1_del_q        <= 1'b0;
            s1_read_q       <= 1'b0;
            s1_side_q       <= 1'b0;
            s1_partial_q    <= 1'b0;
            s1_price_q      <= '0;
            s1_shares_q     <= '0;
            s1_slot_q       <= '0;
            s1_sym_idx_q    <= '0;
            s1_addr_q       <= '0;
            s1_in_window_q  <= 1'b0;
            s1_cur_q        <= '0;
            // Bypass + counter
            out_of_window_q   <= '0;
            bypass_valid_q    <= 1'b0;
            bypass_addr_q     <= '0;
            bypass_data_q     <= '0;
            // Output regs
            level_evt_valid   <= 1'b0;
            level_evt_side    <= 1'b0;
            level_evt_price   <= '0;
            level_evt_size    <= '0;
            level_evt_sym_idx <= '0;
            level_now_empty   <= 1'b0;
            level_now_active  <= 1'b0;
            read_head         <= '0;
            read_tail         <= '0;
            read_agg_size     <= '0;
            read_count        <= '0;
            add_old_tail      <= '0;
            for (int i = 0; i < N_SYMBOLS * 2 * WINDOW_SIZE_TICKS; i++) begin
                levels[i].head     <= '0;
                levels[i].tail     <= '0;
                levels[i].agg_size <= '0;
                levels[i].count    <= '0;
            end
        end else begin
            // ---------- Stage 0: capture op + issue URAM read ----------
            s1_add_q       <= add_req;
            s1_del_q       <= del_req;
            s1_read_q      <= read_req;
            s1_side_q      <= op_side;
            s1_partial_q   <= op_partial;
            s1_price_q     <= op_price;
            s1_shares_q    <= op_shares;
            s1_slot_q      <= op_slot;
            s1_sym_idx_q   <= op_sym_idx;
            s1_addr_q      <= a_d;
            s1_in_window_q <= in_win_d;
            s1_cur_q       <= read_level_d(a_d);

            // ---------- Stage 1: commit write + emit pulses ----------
            // Defaults: pulses deassert each cycle; bypass invalidates
            // unless a write fires below.
            level_evt_valid  <= 1'b0;
            level_now_empty  <= 1'b0;
            level_now_active <= 1'b0;
            level_evt_size   <= '0;
            bypass_valid_q   <= 1'b0;

            if (s1_add_q) begin : add_path
                if (!s1_in_window_q) begin
                    out_of_window_q <= out_of_window_q + 1'b1;
                end else begin
                    levels[s1_addr_q] <= s1_nxt_d;
                    add_old_tail      <= s1_cur_q.tail;

                    bypass_valid_q <= 1'b1;
                    bypass_addr_q  <= s1_addr_q;
                    bypass_data_q  <= s1_nxt_d;

                    // level_evt_* fires on EVERY in-window committed op so
                    // lob_core can drive tob_update_size_req for size-only
                    // changes on already-active levels (tob_tracker filters
                    // internally to "is this the current best price?").
                    // level_now_active is still strictly the 0->1 transition.
                    level_evt_valid   <= 1'b1;
                    level_evt_side    <= s1_side_q;
                    level_evt_price   <= s1_price_q;
                    level_evt_size    <= s1_nxt_d.agg_size;
                    level_evt_sym_idx <= s1_sym_idx_q;
                    if (s1_cur_q.count == 16'd0) begin
                        level_now_active <= 1'b1;
                    end
                end
            end else if (s1_del_q) begin : del_path
                if (!s1_in_window_q) begin
                    out_of_window_q <= out_of_window_q + 1'b1;
                end else begin
                    levels[s1_addr_q] <= s1_nxt_d;

                    bypass_valid_q <= 1'b1;
                    bypass_addr_q  <= s1_addr_q;
                    bypass_data_q  <= s1_nxt_d;

                    // level_evt_* fires on EVERY in-window committed del
                    // (full or partial), not just on empty transitions.
                    level_evt_valid   <= 1'b1;
                    level_evt_side    <= s1_side_q;
                    level_evt_price   <= s1_price_q;
                    level_evt_size    <= s1_nxt_d.agg_size;   // = 0 for emptied
                    level_evt_sym_idx <= s1_sym_idx_q;
                    if (!s1_partial_q && (s1_nxt_d.count == 16'd0)) begin
                        level_now_empty <= 1'b1;
                    end
                end
            end

            if (s1_read_q) begin : read_path
                read_head     <= s1_cur_q.head;
                read_tail     <= s1_cur_q.tail;
                read_agg_size <= s1_cur_q.agg_size;
                read_count    <= s1_cur_q.count;
            end
        end
    end

    // ------------------------------------------------------------------
    // Token reference to the package-mirror parameters so Verilator does
    // not flag them as UNUSEDPARAM. These exist purely to "consume" the
    // package symbols on the lint cmdline; their values do not influence
    // datapath behaviour.
    // ------------------------------------------------------------------
    logic _unused_pkg;
    assign _unused_pkg = |{
        // F.2 §2: WINDOW_BASE_TICK (module-local) is now unused — addr_of
        // and in_window_with_origin both consume op_origin. Touch it
        // here to keep -Wall happy.
        WINDOW_BASE_TICK[0],
        PKG_WINDOW_BASE_TICK[0],
        PKG_WINDOW_SIZE_TICKS[0],
        PKG_SYMBOL_FILTER_ID[0],
        PKG_POOL_SLOTS[0],
        PKG_HASH_SLOTS[0],
        PKG_MAX_PROBE_DEPTH[0],
        PKG_HASH_FN[0]
    };

endmodule : price_ladder
