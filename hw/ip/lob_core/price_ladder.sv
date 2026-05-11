// SPDX-License-Identifier: Apache-2.0
// price_ladder — per-tick {head, tail, agg_size, count} state in URAM.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (top-level dataflow), §3.2 step 4-6 (ADD), §3.3 step 3-4 (DELETE),
//   §5.1 (memory architecture), §6 (cycle targets).
//
// One row per (side, tick_offset) holds the price-level head/tail slot
// pointers, aggregate size, and order count. A 1-deep bypass register
// forwards the writeback from cycle N into cycle N+1's read on the same
// address — spec §3.2 calls this out as a correctness requirement (not a
// performance optimisation) for back-to-back same-tick ops.
//
// Bound check: ops outside [WINDOW_BASE_TICK, WINDOW_BASE_TICK+WINDOW_SIZE_TICKS)
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

    output logic [31:0]                out_of_window
);
    localparam int unsigned OFFS_W = $clog2(WINDOW_SIZE_TICKS);
    localparam int unsigned ADDR_W = OFFS_W + 1;   // +1 MSB for side

    typedef struct packed {
        logic [SLOT_IDX_W-1:0] head;
        logic [SLOT_IDX_W-1:0] tail;
        logic [31:0]           agg_size;
        logic [15:0]           count;
    } level_t;

    (* ram_style = "ultra" *)
    level_t levels [2 * WINDOW_SIZE_TICKS];

    logic [31:0] out_of_window_q;
    assign out_of_window = out_of_window_q;

    // Bypass register for same-tick back-to-back ops. Spec §3.2 correctness
    // requirement, not a performance optimisation.
    logic               bypass_valid_q;
    logic [ADDR_W-1:0]  bypass_addr_q;
    level_t             bypass_data_q;

    function automatic logic in_window(input logic [31:0] p);
        return (p >= WINDOW_BASE_TICK) && (p < (WINDOW_BASE_TICK + WINDOW_SIZE_TICKS));
    endfunction

    function automatic logic [ADDR_W-1:0] addr_of(input logic side, input logic [31:0] p);
        // Truncate-on-assign to OFFS_W bits — only the low bits of (p - BASE)
        // matter once we've already gated on in_window().
        logic [OFFS_W-1:0] offs;
        offs = OFFS_W'(p - WINDOW_BASE_TICK);
        return {side, offs};
    endfunction

    function automatic level_t read_level(input logic [ADDR_W-1:0] a);
        if (bypass_valid_q && (bypass_addr_q == a)) return bypass_data_q;
        return levels[a];
    endfunction

    // The plan suggests inline `automatic` declarations between statements
    // inside the always_ff. Older Verilator releases reject those, so we
    // hoist the temporaries to the top of named begin/end blocks (still
    // inside the if/else if). Reported in the DONE deviations note.
    always_ff @(posedge clk) begin
        if (!rstn) begin
            out_of_window_q  <= '0;
            bypass_valid_q   <= 1'b0;
            bypass_addr_q    <= '0;
            bypass_data_q    <= '0;
            level_evt_valid  <= 1'b0;
            level_evt_side   <= 1'b0;
            level_evt_price  <= '0;
            level_evt_size   <= '0;
            level_now_empty  <= 1'b0;
            level_now_active <= 1'b0;
            read_head        <= '0;
            read_tail        <= '0;
            read_agg_size    <= '0;
            read_count       <= '0;
            add_old_tail     <= '0;
            for (int i = 0; i < 2 * WINDOW_SIZE_TICKS; i++) begin
                levels[i].head     <= '0;
                levels[i].tail     <= '0;
                levels[i].agg_size <= '0;
                levels[i].count    <= '0;
            end
        end else begin
            // Default: pulse outputs deassert each cycle.
            level_evt_valid  <= 1'b0;
            level_now_empty  <= 1'b0;
            level_now_active <= 1'b0;
            level_evt_size   <= '0;

            if (add_req) begin : add_path
                logic [ADDR_W-1:0] a;
                level_t            cur;
                level_t            nxt;

                if (!in_window(op_price)) begin
                    out_of_window_q <= out_of_window_q + 1'b1;
                    bypass_valid_q  <= 1'b0;
                end else begin
                    a   = addr_of(op_side, op_price);
                    cur = read_level(a);

                    nxt.tail     = op_slot;
                    nxt.agg_size = cur.agg_size + op_shares;
                    nxt.count    = cur.count + 16'd1;
                    nxt.head     = (cur.count == 16'd0) ? op_slot : cur.head;

                    add_old_tail   <= cur.tail;
                    levels[a]      <= nxt;
                    bypass_valid_q <= 1'b1;
                    bypass_addr_q  <= a;
                    bypass_data_q  <= nxt;

                    // level_evt_* fires on EVERY in-window committed op so
                    // lob_core can drive tob_update_size_req for size-only
                    // changes on already-active levels (tob_tracker filters
                    // internally to "is this the current best price?").
                    // level_now_active is still strictly the 0->1 transition.
                    level_evt_valid <= 1'b1;
                    level_evt_side  <= op_side;
                    level_evt_price <= op_price;
                    level_evt_size  <= nxt.agg_size;
                    if (cur.count == 16'd0) begin
                        level_now_active <= 1'b1;
                    end
                end
            end else if (del_req) begin : del_path
                logic [ADDR_W-1:0] a;
                level_t            cur;
                level_t            nxt;

                if (!in_window(op_price)) begin
                    out_of_window_q <= out_of_window_q + 1'b1;
                    bypass_valid_q  <= 1'b0;
                end else begin
                    a   = addr_of(op_side, op_price);
                    cur = read_level(a);

                    nxt          = cur;
                    nxt.agg_size = cur.agg_size - op_shares;
                    // Partial X/E leaves the order alive — only agg
                    // shrinks. count / head / tail unchanged. Full
                    // removal (D, or X/E that zero an order) decrements
                    // count by 1 and may transition to empty.
                    if (!op_partial) begin
                        nxt.count = cur.count - 16'd1;
                    end

                    levels[a]      <= nxt;
                    bypass_valid_q <= 1'b1;
                    bypass_addr_q  <= a;
                    bypass_data_q  <= nxt;

                    // level_evt_* fires on EVERY in-window committed del
                    // (full or partial), not just on empty transitions.
                    level_evt_valid <= 1'b1;
                    level_evt_side  <= op_side;
                    level_evt_price <= op_price;
                    level_evt_size  <= nxt.agg_size;   // = 0 for emptied
                    if (!op_partial && (nxt.count == 16'd0)) begin
                        level_now_empty <= 1'b1;
                    end
                end
            end else begin
                // No write this cycle — invalidate the bypass so a stale
                // forward doesn't shadow a fresh URAM read.
                bypass_valid_q <= 1'b0;
            end

            if (read_req) begin : read_path
                logic [ADDR_W-1:0] a;
                level_t            cur;
                a   = addr_of(op_side, op_price);
                cur = read_level(a);
                read_head     <= cur.head;
                read_tail     <= cur.tail;
                read_agg_size <= cur.agg_size;
                read_count    <= cur.count;
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
        PKG_WINDOW_BASE_TICK[0],
        PKG_WINDOW_SIZE_TICKS[0],
        PKG_SYMBOL_FILTER_ID[0],
        PKG_POOL_SLOTS[0],
        PKG_HASH_SLOTS[0],
        PKG_MAX_PROBE_DEPTH[0],
        PKG_HASH_FN[0]
    };

endmodule : price_ladder
