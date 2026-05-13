// SPDX-License-Identifier: Apache-2.0
// price_ladder — per-tick {head, tail, agg_size, count} state in URAM.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (top-level dataflow), §3.2 step 4-6 (ADD), §3.3 step 3-4 (DELETE),
//   §5.1 (memory architecture), §6 (cycle targets).
//
// One row per (side, tick_offset) holds the price-level head/tail slot
// pointers, aggregate size, and order count. A 1-deep bypass register
// forwards a previous-cycle writeback onto a same-address read; the
// bypass mux sits DOWNSTREAM of the URAM output register (see
// `s1_cur_eff` below) so the URAM cell is inferred cleanly. This
// satisfies spec §3.2's correctness requirement under the 2-stage
// pipeline.
//
// 2026-05-13 amendment — registered URAM read:
//   Pre-amendment the level URAM was read combinationally inside an
//   always_ff (read_level() called in the same cycle as the writeback).
//   Vivado could not infer URAM/BRAM and the `levels` array fell back
//   to flip-flops (393K FFs at the smoke config @ N_SYMBOLS=4 — three
//   orders of magnitude too many at production sizing).
//
//   The amended module pipelines into two stages:
//     - Stage 0 (input cycle): compute `a_d = addr_of(...)` and
//       `in_win_d = in_window_with_origin(...)` combinationally. Latch
//       op metadata into s1_*_q registers and issue a pure URAM
//       sync-read (`s1_cur_q <= levels[a_d]` — no muxes upstream of
//       this NBA, which is the key to URAM inference).
//     - Stage 1 (commit cycle): apply bypass forwarding combinationally
//       (s1_cur_eff = bypass_match ? bypass_data_q : s1_cur_q), use
//       s1_cur_eff + s1_*_q to compute `nxt`, write levels[s1_addr_q]
//       <= nxt, update the bypass register, and emit the level_evt_*
//       pulse + the read_head/tail/agg_size/count registers.
//
//   2026-05-13 follow-up — downstream forwarding:
//     The original amendment kept the forwarding mux UPSTREAM of the
//     URAM output register (read_level_d() called inside the NBA),
//     which still failed URAM inference (silent fallback to a 282K-LUT
//     MUXF7/F8 tree, owning the WNS path at -0.108 ns). This revision
//     moves the bypass mux downstream into stage 1 (s1_cur_eff) and
//     drops the in-flight forwarding entirely: pure URAM read in stage 0
//     returns the pre-write value, and at the next cycle bypass_q
//     already holds the committed write — bypass alone covers every
//     back-to-back same-address case.
//
//   Latency consequence (spec §6): ADD, DEL, and read each +1 cycle
//   versus the pre-amendment single-cycle path.
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

    localparam int unsigned LEVEL_W  = $bits(level_t);
    localparam int unsigned N_LEVELS = N_SYMBOLS * 2 * WINDOW_SIZE_TICKS;

    // Levels storage — instantiated via the uram_sdp wrapper instead of an
    // inline `level_t levels[]` array. The earlier (committed) form declared
    // the array as a packed-struct, which Vivado decomposed PER FIELD
    // (`levels[i][head]`, `levels[i][tail]`, etc.) — Synth 8-7186 fired 100+
    // times in the 2026-05-13 OOC synth and `ram_style="ultra"` was silently
    // ignored, falling back to 393 K flip-flops. uram_sdp keeps storage as
    // a single flat WIDTH-bit array (the order_pool.records_reg shape) so
    // Vivado folds it into a real URAM cell. Pack/unpack of `level_t`
    // happens at the wrapper boundary below.
    logic               mem_we_w;
    logic [LEVEL_W-1:0] mem_wdata_w;
    logic [LEVEL_W-1:0] mem_rdata_w;     // 1-cycle-registered read output

    uram_sdp #(
        .WIDTH (LEVEL_W),
        .DEPTH (N_LEVELS)
    ) u_levels (
        .clk   (clk),
        .we    (mem_we_w),
        .waddr (s1_addr_q),
        .wdata (mem_wdata_w),
        .re    (1'b1),
        .raddr (a_d),
        .rdata (mem_rdata_w)
    );

    // Per-level "active" bits — FF-backed flat bit-vector, resets to 0 in
    // a single cycle on rstn=0. URAM cells have no reset port, so the
    // payload mem[] retains its contents across rstn; the active flag is
    // the authoritative source of "this level is non-empty" and gates the
    // URAM read result during stage-1 nxt computation (an inactive level
    // is treated as cur.count=0 regardless of stale URAM contents). The
    // flag is set when count transitions 0→N and cleared when count
    // returns to 0.
    //
    // Storage at smoke sizing (N_SYMBOLS=4, WINDOW_SIZE_TICKS=512):
    // 4096 FFs. Production sizing pushes this toward 1 M FFs; revisiting
    // it (move to URAM with an explicit clearing FSM, or per-symbol
    // packed bitmaps) is Phase K work.
    logic [N_LEVELS-1:0] level_active_q;
    logic                s1_cur_active_q;

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
    // Stage-1 pipeline registers — capture op metadata. The URAM read
    // result is supplied by the uram_sdp wrapper's registered rdata; no
    // separate s1_cur_q register is needed (the wrapper IS the register).
    // ----------------------------------------------------------------------
    logic                       s1_add_q, s1_del_q, s1_read_q;
    logic                       s1_side_q, s1_partial_q;
    logic [31:0]                s1_price_q, s1_shares_q;
    logic [SLOT_IDX_W-1:0]      s1_slot_q;
    logic [SYM_IDX_W-1:0]       s1_sym_idx_q;
    logic [ADDR_W-1:0]          s1_addr_q;
    logic                       s1_in_window_q;

    // Combinational stage-0 helpers.
    logic [ADDR_W-1:0]          a_d;
    logic                       in_win_d;
    always_comb begin
        a_d      = addr_of(op_sym_idx, op_side, op_price, op_origin);
        in_win_d = in_window_with_origin(op_price, op_origin);
    end

    // URAM read view as a level_t. The wrapper returns a flat WIDTH-bit
    // vector; we cast back to the struct here. The result is gated by
    // s1_cur_active_q: an inactive level reads as all-zeros (cur.count=0)
    // regardless of whatever stale data the URAM cell holds. Together with
    // the FF-backed level_active_q this gives clean post-reset behaviour
    // without needing a per-cell URAM clear loop (which is what blocked
    // URAM inference pre-fix).
    level_t s1_cur_w;
    always_comb begin
        if (s1_cur_active_q) begin
            s1_cur_w = level_t'(mem_rdata_w);
        end else begin
            s1_cur_w = '0;
        end
    end

    // Stage-1 bypass forwarding mux. s1_cur_w carries the unbypassed URAM
    // read (registered inside uram_sdp); s1_cur_eff applies the 1-cycle-
    // stale bypass register on top, so the nxt compute / commit / read-path
    // logic below see the freshest committed value.
    //
    // Why bypass alone is sufficient (no in-flight forward needed):
    //   - Pure URAM read in stage 0 returns the levels[] value as of the
    //     start of that cycle (BRAM/URAM read-before-write semantics).
    //   - The only hazard is back-to-back same-address ops: op-A in
    //     stage 1 commits at NBA of cycle N, op-B in stage 0 reads
    //     levels[addr] at cycle N and gets the pre-NBA (stale) value.
    //   - At cycle N+1 op-B is in stage 1; bypass_valid_q=1 and
    //     bypass_addr_q matches → forward. For ops spaced 2+ cycles
    //     apart, levels[] is already up to date and the bypass mux
    //     selects s1_cur_w.
    level_t s1_cur_eff;
    always_comb begin
        if (bypass_valid_q && (bypass_addr_q == s1_addr_q)) begin
            s1_cur_eff = bypass_data_q;
        end else begin
            s1_cur_eff = s1_cur_w;
        end
    end

    // Combinational stage-1 nxt. Driven from s1_cur_eff (bypass-forwarded),
    // not from the raw URAM register. Drives the URAM write (via uram_sdp
    // .wdata) and the level_evt_size pulse.
    level_t s1_nxt_d;
    always_comb begin
        s1_nxt_d = '0;
        if (s1_add_q && s1_in_window_q) begin
            s1_nxt_d.tail       = s1_slot_q;
            s1_nxt_d.agg_size   = s1_cur_eff.agg_size + s1_shares_q;
            s1_nxt_d.count      = s1_cur_eff.count + 16'd1;
            s1_nxt_d.head       = (s1_cur_eff.count == 16'd0) ? s1_slot_q : s1_cur_eff.head;
        end else if (s1_del_q && s1_in_window_q) begin
            s1_nxt_d            = s1_cur_eff;
            s1_nxt_d.agg_size   = s1_cur_eff.agg_size - s1_shares_q;
            if (!s1_partial_q) begin
                s1_nxt_d.count  = s1_cur_eff.count - 16'd1;
            end
        end
    end

    // Wrapper write enable: any in-window committed ADD or DEL in stage 1.
    // wdata is the packed view of s1_nxt_d. The wrapper handles the actual
    // URAM write on the clock edge.
    assign mem_we_w    = (s1_add_q || s1_del_q) && s1_in_window_q;
    assign mem_wdata_w = LEVEL_W'(s1_nxt_d);

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
            s1_cur_active_q <= 1'b0;
            // Wide bit-vector reset: at production sizing (N_LEVELS = 1 M)
            // the replication width trips Verilator's default
            // --replication-limit. Waiver until Phase K production sizing
            // moves level_active to URAM (with the same `initial`-based
            // zero init as the payload mem).
            /* verilator lint_off WIDTHCONCAT */
            level_active_q  <= '0;
            /* verilator lint_on WIDTHCONCAT */
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
            // NOTE: the URAM-backed levels[] storage is NOT reset here —
            // URAM cells have no reset port, and the `for (int i = 0; ...;
            // levels[i].field <= '0)` loop was the exact pattern that
            // forced Vivado to per-field decompose the struct array and
            // ignore `ram_style = "ultra"` (Synth 8-7186 ×100+). The
            // uram_sdp wrapper handles config-time zero-init via its own
            // `initial` block.
        end else begin
            // ---------- Stage 0: capture op + issue URAM read ----------
            // The URAM read itself is driven by the uram_sdp instance —
            // .re tied high, .raddr = a_d combinationally. The wrapper's
            // .rdata is registered (1-cycle latency) and is consumed in
            // stage 1 via s1_cur_w / s1_cur_eff.
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
            // Capture the active flag for the address we're reading,
            // synchronously alongside the URAM read.
            s1_cur_active_q <= level_active_q[a_d];

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
                    // URAM write fires via uram_sdp this cycle (mem_we_w
                    // assigned combinationally above); capture old tail,
                    // update the bypass forward, and mark the level
                    // active (ADD never produces count=0, so this is
                    // unconditionally `1`).
                    add_old_tail      <= s1_cur_eff.tail;
                    level_active_q[s1_addr_q] <= 1'b1;

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
                    if (s1_cur_eff.count == 16'd0) begin
                        level_now_active <= 1'b1;
                    end
                end
            end else if (s1_del_q) begin : del_path
                if (!s1_in_window_q) begin
                    out_of_window_q <= out_of_window_q + 1'b1;
                end else begin
                    // URAM write fires via uram_sdp; update the bypass
                    // forward, and clear the level-active bit if this
                    // DEL drove count to 0 (full removal of the last
                    // order on this level).
                    bypass_valid_q <= 1'b1;
                    bypass_addr_q  <= s1_addr_q;
                    bypass_data_q  <= s1_nxt_d;
                    if (!s1_partial_q && (s1_nxt_d.count == 16'd0)) begin
                        level_active_q[s1_addr_q] <= 1'b0;
                    end

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
                read_head     <= s1_cur_eff.head;
                read_tail     <= s1_cur_eff.tail;
                read_agg_size <= s1_cur_eff.agg_size;
                read_count    <= s1_cur_eff.count;
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
