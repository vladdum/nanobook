// SPDX-License-Identifier: Apache-2.0
// lob_core — top-level orchestrator for the M05 single-symbol L3 book.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (top-level dataflow), §3.2 (ADD pipeline 4 cycles),
//   §3.3 (DELETE pipeline 5 cycles), §3.4 (EXEC/CANCEL/EXEC_PX),
//   §3.5 (symbol filter), §6 (cycle targets table).
// Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md
//   Task 23 (this file).
//
// Pipelined orchestrator with explicit per-stage valid registers so the
// happy path runs at 1 event/cycle (steady-state target). Two paths:
//
//   ADD path  — 4 stages: a1 (alloc + ladder_read), a2 (pool_write +
//               hash_insert + ladder_add), a3 (pool linkage write,
//               level_evt visible), a4 (tob_tracker registers m_tvalid;
//               events_in bumps).
//
//   DEL path  — 5 stages: d1 (hash_lookup), d2 (capture slot, pool_read0),
//               d3 (pool record visible -> splice + ladder_del), d4
//               (ladder updated; level_evt visible; pool free push), d5
//               (events_in bumps; tob_tracker emits if best changed).
//
// EXEC / EXEC_PX / CANCEL_PARTIAL are routed onto the DEL path with a
// "decrement-only" flag (no splice, no free-list push) when the executed
// quantity does not zero the order; if it does zero, they collapse to a
// full DEL (spec §3.4). For M05 the EXEC fast-path collapses entirely
// to DEL — partial EXEC tracking lives in the order record's `shares`
// field which is read at the splice stage and adjusted in-place; this
// keeps EXEC and DEL on the same 5-cycle path.
//
// Symbol filter (§3.5): events with `symbol_id != SYMBOL_FILTER_ID` are
// dropped at the input handshake, bumping `events_filtered`. They do NOT
// enter either pipeline; they cost 1 cycle.
//
// `events_in` is bumped at the END of the pipeline (a4 for ADD, d5 for
// DEL) — this is the contract the cycle-accurate TB measures
// (tb_lob_core_cycles.test_delete_5_cycles_first_probe). Filter drops
// bump `events_filtered` at the input handshake (cost: 1 cycle).
//
// `cur_ts_q` is a free-running cycle counter forwarded to tob_tracker
// for emit_ts. The ingress_ts of the *event being emitted by tob_tracker*
// is forwarded through the pipeline so the emitted tob_delta carries the
// right per-event ingress_ts.

`include "book_event_pkg.sv"

module lob_core
  import book_event_pkg::*;
  import lob_core_params_pkg::*;
#(
    // Defaults are LITERALS rather than package references to keep
    // Vivado's `synth_design -top lob_core` happy — Vivado 2025.2 can't
    // resolve `lob_core_params_pkg::SYMBOL_FILTER_ID` in parameter
    // defaults when the package itself was just elaborated in the same
    // synth run. The lob_core_params_pkg.sv values mirror these
    // literals (Phase B emitted both); the orchestrator's instantiation
    // still passes the package values via parameter override. For OOC
    // smoke synth, the synth.tcl uses smaller overrides so URAM /
    // distRAM size limits don't trip elaboration.
    /* verilator lint_off VARHIDDEN */
    parameter int unsigned SYMBOL_FILTER_ID  = 5754,
    parameter int unsigned WINDOW_BASE_TICK  = 354000,
    parameter int unsigned WINDOW_SIZE_TICKS = 4096,
    parameter int unsigned POOL_SLOTS        = 8192,
    parameter int unsigned HASH_SLOTS        = 65536,
    parameter int unsigned MAX_PROBE_DEPTH   = 4,
    // M06 sizing: defaults to the package's N_SYMBOLS but exposed as a
    // parameter so Vivado OOC smoke synth can override to a small value
    // (the per-sym ladder URAM is N_SYMBOLS × 2 × WINDOW_SIZE_TICKS × 96b;
    // at full size that exceeds Vivado's per-variable elaboration limit).
    parameter int unsigned N_SYMBOLS         = lob_core_params_pkg::N_SYMBOLS,
    /* verilator lint_on VARHIDDEN */
    parameter int unsigned IN_DATA_W         = 256,
    parameter int unsigned OUT_DATA_W        = 256
) (
    input  logic                   clk,
    input  logic                   rstn,

    // Input AXI-S — book_event_t from itch_decoder
    input  logic [IN_DATA_W-1:0]   s_tdata,
    input  logic                   s_tvalid,
    output logic                   s_tready,
    input  logic                   s_tlast,

    // Output AXI-S — tob_delta_t
    output logic [OUT_DATA_W-1:0]  m_tdata,
    output logic                   m_tvalid,
    input  logic                   m_tready,
    output logic                   m_tlast,

    // Stat counters (read-only; plumbed to BAR0 in M10)
    output logic [31:0]            events_in,
    output logic [31:0]            events_filtered,
    output logic [31:0]            tob_deltas_out,
    output logic [7:0]             hash_probe_max,
    output logic [31:0]            hash_overflow,
    output logic [31:0]            pool_exhausted,
    output logic [31:0]            out_of_window,
    output logic [31:0]            unknown_order,
    output logic [31:0]            cancel_underflow,

    // M06 test-only backdoor — synthesisable (Vivado optimises unused input)
    input  logic                              dbg_epoch_bump,

    // M06 stat counters
    output logic [31:0]                       rebases_total,
    output logic [31:0]                       stale_drops,
    output logic [31:0]                       pool_leaks_freed,
    output logic [31:0]                       sym_lut_misses,
    output logic [31:0]                       epoch_wraps
);
    localparam int unsigned SLOT_IDX_W = 24;
    localparam int unsigned POOL_IDX_W = $clog2(POOL_SLOTS);
    localparam int unsigned RECORD_W   = 256;

    // Suppress UNUSEDPARAM on POOL_SLOTS / etc. when overridden — the
    // sub-modules consume them but Verilator's UNUSEDPARAM check looks
    // at this top-level module only. Anchored as a localparam touch.
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned _UNUSED_HASH_SLOTS      = HASH_SLOTS;
    localparam int unsigned _UNUSED_MAX_PROBE_DEPTH = MAX_PROBE_DEPTH;
    /* verilator lint_on UNUSEDPARAM */

    // ------------------------------------------------------------------
    // Sub-module wiring
    // ------------------------------------------------------------------
    logic                            pool_alloc_req, pool_alloc_valid;
    logic [POOL_IDX_W-1:0]           pool_alloc_slot;
    logic                            pool_free_req;
    logic [POOL_IDX_W-1:0]           pool_free_slot;
    logic                            pool_write_req;
    logic [POOL_IDX_W-1:0]           pool_write_slot;
    logic [RECORD_W-1:0]             pool_write_record;
    logic                            pool_read0_req, pool_read1_req;
    logic [POOL_IDX_W-1:0]           pool_read0_slot, pool_read1_slot;
    logic [RECORD_W-1:0]             pool_read0_record, pool_read1_record;
    logic [31:0]                     pool_exhausted_w;

    /* verilator lint_off UNUSEDSIGNAL */
    // pool_read1_record / pool_alloc_valid are sampled only on the DEL /
    // alloc-failure paths exercised by the integration TB (Phase I);
    // the cycle-accurate TB does not depend on their values directly.
    // pool_read1_record is reserved for the EXEC fast-path that reads
    // both head and current order in parallel (Phase I).
    /* verilator lint_on UNUSEDSIGNAL */

    order_pool #(
        .POOL_SLOTS (POOL_SLOTS),
        .RECORD_W   (RECORD_W)
    ) u_pool (
        .clk(clk), .rstn(rstn),
        .alloc_req(pool_alloc_req), .alloc_valid(pool_alloc_valid),
        .alloc_slot(pool_alloc_slot),
        .free_req(pool_free_req), .free_slot(pool_free_slot),
        .write_req(pool_write_req), .write_slot(pool_write_slot),
        .write_record(pool_write_record),
        .read0_req(pool_read0_req), .read0_slot(pool_read0_slot),
        .read0_record(pool_read0_record),
        .read1_req(pool_read1_req), .read1_slot(pool_read1_slot),
        .read1_record(pool_read1_record),
        .pool_exhausted(pool_exhausted_w)
    );

    logic            hash_insert_req, hash_delete_req, hash_lookup_req;
    logic [63:0]     hash_oid;
    logic [SLOT_IDX_W-1:0] hash_slot_in;
    logic            hash_op_done, hash_op_ok;
    logic [SLOT_IDX_W-1:0] hash_slot_out;
    logic [7:0]      hash_probe_max_w;
    logic [31:0]     hash_overflow_w;

    order_id_hash #(
        .HASH_SLOTS      (HASH_SLOTS),
        .MAX_PROBE_DEPTH (MAX_PROBE_DEPTH),
        .SLOT_IDX_W      (SLOT_IDX_W)
    ) u_hash (
        .clk(clk), .rstn(rstn),
        .insert_req(hash_insert_req), .delete_req(hash_delete_req),
        .lookup_req(hash_lookup_req),
        .order_id(hash_oid), .slot_idx_in(hash_slot_in),
        .op_done(hash_op_done), .op_ok(hash_op_ok),
        .slot_idx_out(hash_slot_out),
        .hash_probe_max(hash_probe_max_w),
        .hash_overflow(hash_overflow_w)
    );

    logic            ladder_add_req, ladder_del_req, ladder_read_req;
    logic            ladder_op_side;
    logic [31:0]     ladder_op_price;
    logic [SLOT_IDX_W-1:0] ladder_op_slot;
    logic [31:0]     ladder_op_shares;
    logic            ladder_op_partial;
    logic [SLOT_IDX_W-1:0] ladder_read_head, ladder_read_tail, ladder_add_old_tail;
    logic [31:0]     ladder_read_agg_size;
    logic [15:0]     ladder_read_count;
    logic            ladder_level_now_empty, ladder_level_now_active, ladder_level_evt_valid;
    logic            ladder_level_evt_side;
    logic [31:0]     ladder_level_evt_price;
    logic [31:0]     ladder_level_evt_size;
    logic [SYM_IDX_W-1:0] ladder_level_evt_sym_idx_w;
    logic [SYM_IDX_W-1:0] ladder_op_sym_idx_w;
    logic [31:0]          ladder_op_origin_w;
    logic [31:0]     out_of_window_w;

    /* verilator lint_off UNUSEDSIGNAL */
    // ladder_read_head / read_count are exposed for Phase I integration TB
    // probing but the cycle-accurate orchestrator only needs read_tail
    // (for pool linkage) and read_agg_size (for tob update_size_req).
    // ladder_level_evt_valid is currently informational; level transitions
    // are routed via the level_now_active / level_now_empty pulses.
    /* verilator lint_on UNUSEDSIGNAL */

    price_ladder #(
        .WINDOW_BASE_TICK  (WINDOW_BASE_TICK),
        .WINDOW_SIZE_TICKS (WINDOW_SIZE_TICKS),
        .N_SYMBOLS         (N_SYMBOLS),
        .SLOT_IDX_W        (SLOT_IDX_W)
    ) u_ladder (
        .clk(clk), .rstn(rstn),
        .add_req(ladder_add_req), .del_req(ladder_del_req),
        .read_req(ladder_read_req),
        // M06 F.2 §1: sym_idx is muxed by the orchestrator from the pipeline
        // stage that drives the current op (a2 for ADD, d3 for DEL, a1 or
        // clr_fu1 for reads). Default tie-off at '0 retained for paths that
        // don't yet drive it (the always_comb below covers every path).
        .op_sym_idx(ladder_op_sym_idx_w),
        // F.2 §2: per-op origin sourced from per_sym_state (lut_sym_idx_w
        // for ADD/read; clr_fu_sym_idx_q for clr_fu1 ladder_read; d3's
        // latched ins_origin for DEL — d3 reads `read2_origin` via a new
        // per_sym_state port (deferred sub-task; for now DEL uses the
        // static WINDOW_BASE_TICK so its address math matches the original
        // ADD insertion at that origin — see §F.2 deferral note).
        .op_origin(ladder_op_origin_w),
        .op_side(ladder_op_side), .op_price(ladder_op_price),
        .op_slot(ladder_op_slot), .op_shares(ladder_op_shares),
        .op_partial(ladder_op_partial),
        .read_head(ladder_read_head), .read_tail(ladder_read_tail),
        .read_agg_size(ladder_read_agg_size), .read_count(ladder_read_count),
        .add_old_tail(ladder_add_old_tail),
        .level_now_empty(ladder_level_now_empty),
        .level_now_active(ladder_level_now_active),
        .level_evt_valid(ladder_level_evt_valid),
        .level_evt_side(ladder_level_evt_side),
        .level_evt_price(ladder_level_evt_price),
        .level_evt_size(ladder_level_evt_size),
        .level_evt_sym_idx(ladder_level_evt_sym_idx_w),
        .out_of_window(out_of_window_w)
    );

    // tob_tracker driven from ladder level transitions; the orchestrator
    // forwards ingress_ts of the currently-emitting event via the pipe
    // register `tob_ingress_ts_q` (latched from the stage that triggers
    // the level transition).
    logic [63:0]     cur_ts_q;
    logic [63:0]     tob_ingress_ts_q;
    logic [7:0]      tob_op_reason_q;
    logic            tob_update_size_req;
    logic            tob_update_size_side;
    logic [31:0]     tob_update_size_price;
    logic [31:0]     tob_update_size_value;

    // Deferred clr-emit follow-up. tob_tracker pulses pending_clr_valid_o
    // when clr_bit_req empties the current best AND a new best exists;
    // it suppresses the placeholder emit (which would carry size=0). We
    // latch the new best's coordinates here, fire ladder_read_req in the
    // following cycle, and drive tob_update_size_req with the correct
    // size the cycle after that — so tob_tracker's update_size branch
    // emits the actual delta with new_best_size = the level's agg.
    logic            tob_pending_clr_valid_w;
    logic            tob_pending_clr_side_w;
    logic [31:0]     tob_pending_clr_price_w;
    logic [63:0]     tob_pending_clr_ingress_ts_w;
    logic [7:0]      tob_pending_clr_reason_w;
    logic [SYM_IDX_W-1:0] tob_pending_clr_sym_idx_w;

    // Two-stage follow-up: clr_fu1 = ladder_read fires; clr_fu2 =
    // ladder_read_agg_size visible, drive update_size_req.
    logic            clr_fu1_valid_q, clr_fu2_valid_q;
    logic            clr_fu_side_q;
    logic [31:0]     clr_fu_price_q;
    logic [63:0]     clr_fu_ingress_ts_q;
    logic [7:0]      clr_fu_reason_q;
    logic [SYM_IDX_W-1:0] clr_fu_sym_idx_q;

    always_ff @(posedge clk) begin
        if (!rstn) cur_ts_q <= '0;
        else       cur_ts_q <= cur_ts_q + 64'd1;
    end

    // tob_tracker op_side / op_price / op_size are muxed: bitmap-set/clear
    // come from the ladder; size-update comes from the orchestrator's
    // EXEC fast-path (currently ladder-driven only — update_size_req
    // tied 0 for M05; reserved for an EXEC-no-zero fast-path in Phase I).
    logic            tob_op_side_w;
    logic [31:0]     tob_op_price_w;
    logic [31:0]     tob_op_size_w;
    logic [SYM_IDX_W-1:0] tob_op_sym_idx_w;
    always_comb begin
        if (tob_update_size_req) begin
            tob_op_side_w  = tob_update_size_side;
            tob_op_price_w = tob_update_size_price;
            tob_op_size_w  = tob_update_size_value;
            // For a clr_fu2-driven update_size_req (deferred clr emit), the
            // sym_idx is whatever the original clr was on. Otherwise the
            // tob_update_size_req comes from ladder_level_evt_valid, so the
            // ladder's level_evt_sym_idx is the source.
            tob_op_sym_idx_w = clr_fu2_valid_q ? clr_fu_sym_idx_q
                                               : ladder_level_evt_sym_idx_w;
        end else begin
            // Phase I fix: tob_tracker's set_bit/clr_bit branches need the
            // POST-op aggregate, not the LAST READ of the ladder. The ladder
            // emits level_evt_size coincident with level_now_active /
            // level_now_empty pulses (post-add agg = op_shares for new
            // levels; post-del agg = 0 for emptied levels). Forward that.
            tob_op_side_w    = ladder_level_evt_side;
            tob_op_price_w   = ladder_level_evt_price;
            tob_op_size_w    = ladder_level_evt_size;
            tob_op_sym_idx_w = ladder_level_evt_sym_idx_w;
        end
    end

    // ingress_ts / op_reason override mux: when the clr followup fires
    // tob_update_size_req for a deferred clr-emit, use the ingress_ts /
    // reason captured from the originating event (latched in clr_fu_*_q).
    // Otherwise use the orchestrator's pipeline-latched values.
    logic [63:0] tob_ingress_ts_w;
    logic [7:0]  tob_op_reason_w;
    always_comb begin
        if (clr_fu2_valid_q) begin
            tob_ingress_ts_w = clr_fu_ingress_ts_q;
            tob_op_reason_w  = clr_fu_reason_q;
        end else begin
            tob_ingress_ts_w = tob_ingress_ts_q;
            tob_op_reason_w  = tob_op_reason_q;
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic        tob_clz_result_valid_unused;
    logic [11:0] tob_clz_result_tick_unused;
    /* verilator lint_on UNUSEDSIGNAL */

    tob_tracker #(
        .WINDOW_BASE_TICK  (WINDOW_BASE_TICK),
        .WINDOW_SIZE_TICKS (WINDOW_SIZE_TICKS),
        .SYMBOL_FILTER_ID  (SYMBOL_FILTER_ID)
    ) u_tob (
        .clk(clk), .rstn(rstn),
        .set_bit_req     (ladder_level_now_active),
        .clr_bit_req     (ladder_level_now_empty),
        .update_size_req (tob_update_size_req),
        .op_side         (tob_op_side_w),
        .op_price        (tob_op_price_w),
        .op_size         (tob_op_size_w),
        .op_reason       (tob_op_reason_w),
        .cur_ts          (cur_ts_q),
        .ingress_ts      (tob_ingress_ts_w),
        .m_tdata                  (m_tdata),
        .m_tvalid                 (m_tvalid),
        .m_tready                 (m_tready),
        .m_tlast                  (m_tlast),
        .pending_clr_valid_o      (tob_pending_clr_valid_w),
        .pending_clr_side_o       (tob_pending_clr_side_w),
        .pending_clr_price_o      (tob_pending_clr_price_w),
        .pending_clr_ingress_ts_o (tob_pending_clr_ingress_ts_w),
        .pending_clr_reason_o     (tob_pending_clr_reason_w),
        .pending_clr_sym_idx_o    (tob_pending_clr_sym_idx_w),
        // M06 F.2 §1: tob_op sym_idx muxed from clr_fu_sym_idx_q (deferred
        // clr emit) vs ladder_level_evt_sym_idx_w (everything else). The
        // ladder forwards op_sym_idx on its level_evt_* bus so the pulse
        // and the sym are synchronised.
        .op_sym_idx               (tob_op_sym_idx_w),
        // M06 D.2: external CLZ kick interface — TB-only path. D.3 wires
        // the CLZ internally on clr-empties-best, so lob_core never
        // drives external kicks and never consumes clz_result_*. Sink
        // the outputs into a dummy net to silence PINCONNECTEMPTY
        // (declared below before the instance to satisfy Vivado, which
        // does not auto-create implicit nets for SV outputs).
        .clz_kick                 ('0),
        .clz_kick_sym             ('0),
        .clz_kick_side            ('0),
        .clz_result_valid         (tob_clz_result_valid_unused),
        .clz_result_tick          (tob_clz_result_tick_unused)
    );

    // ------------------------------------------------------------------
    // Event ingress — extract fields from the AXI-S byte-lane layout that
    // hw/ip/itch_decoder/endian_swap.sv produces (BookEvent.pack() order):
    //   TDATA[7:0]      ev_type
    //   TDATA[15:8]     side
    //   TDATA[31:16]    symbol_id (LE)
    //   TDATA[63:32]    price     (LE)
    //   TDATA[95:64]    shares    (LE)
    //   TDATA[127:96]   _pad
    //   TDATA[191:128]  order_id  (LE)
    //   TDATA[255:192]  ingress_ts(LE)
    // The book_event_t SV-packed struct uses MSB-first natural layout —
    // a struct cast on s_tdata would mis-align fields. We therefore
    // extract by bit-range, matching dv/unit/lob_core/_book.py
    // pack_book_event() and Phase I integration TB consumers.
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    // Upper bits of side / ev_type are intentionally unused; spec uses
    // the low bit of side and a 5-value enum for ev_type.
    // The high 3 bits of ev_in_symbol_id (stock_locate) are unused —
    // sym_idx_lut only addresses SYM_LUT_DEPTH=8192 (13-bit) entries.
    logic [7:0]  ev_in_ev_type;
    logic [7:0]  ev_in_side_byte;
    logic [31:0] ev_in_pad;
    logic [15:0] ev_in_symbol_id;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] ev_in_price;
    logic [31:0] ev_in_shares;
    logic [63:0] ev_in_order_id;
    logic [63:0] ev_in_ingress_ts;

    assign ev_in_ev_type    = s_tdata[7:0];
    assign ev_in_side_byte  = s_tdata[15:8];
    assign ev_in_symbol_id  = s_tdata[31:16];
    assign ev_in_price      = s_tdata[63:32];
    assign ev_in_shares     = s_tdata[95:64];
    assign ev_in_pad        = s_tdata[127:96];
    assign ev_in_order_id   = s_tdata[191:128];
    assign ev_in_ingress_ts = s_tdata[255:192];

    logic ev_in_filtered;
    logic ev_in_in_window;
    logic ev_in_is_add;
    logic ev_in_is_del_class;   // D, X, E, ExecPx all share the DEL pipe.

    // M06 E.2 — sym_idx_lut replaces the M05 SYMBOL_FILTER_ID comparator.
    // Combinational distRAM lookup; symbol_id (== ITCH stock_locate) →
    // { valid, sym_idx[6:0] }. Miss → drop the event and bump
    // sym_lut_misses_q. The picked-symbol sym_idx propagates into the ADD
    // pipeline via a1_pl_q.sym_idx (a2_pl_q etc inherit it).
    logic                                            lut_valid_w;
    logic [lob_core_params_pkg::SYM_IDX_W-1:0]       lut_sym_idx_w;

    sym_idx_lut u_sym_idx_lut (
        .stock_locate (ev_in_symbol_id[$clog2(lob_core_sym_pkg::SYM_LUT_DEPTH)-1:0]),
        .valid_o      (lut_valid_w),
        .sym_idx_o    (lut_sym_idx_w)
    );

    assign ev_in_filtered = !lut_valid_w;
    // F.2 §3: per-sym in-window check uses pss_read_origin_w (port 1, driven
    // by lut_sym_idx_w). DEL-class events get the same gate at lob_core
    // input — the actual DEL ladder write later in d3 also re-checks
    // against pss_read2_origin (port 2) when stale_check passes.
    assign ev_in_in_window = (ev_in_price >= pss_read_origin_w) &&
                             (ev_in_price <  pss_read_origin_w + 32'(WINDOW_SIZE_TICKS));
    assign ev_in_is_add        = (ev_in_ev_type == 8'(EV_ADD));
    assign ev_in_is_del_class  = (ev_in_ev_type == 8'(EV_DELETE)) ||
                                 (ev_in_ev_type == 8'(EV_CANCEL)) ||
                                 (ev_in_ev_type == 8'(EV_EXEC))   ||
                                 (ev_in_ev_type == 8'(EV_EXEC_PX));

    // Always-ready policy: the orchestrator's ADD/DEL pipelines accept 1
    // event/cycle on the happy path. Back-pressure (s_tready=0) only
    // appears when the hash sub-module is in a multi-probe ST_PROBE state
    // and a new ADD/DEL needs the hash. Tracked via `hash_busy` below —
    // when the hash is mid-collision-probe, stage 1 of the pipeline waits.
    logic hash_busy;

    // Stage payload bundle — carries everything later stages need so we
    // do NOT re-decode s_tdata once the event has entered the pipeline.
    typedef struct packed {
        logic                  side;
        logic [31:0]           price;
        // shares = event-side quantity. For ADD: order size. For D: 0.
        // For X / E / EXEC_PX: cancel-or-exec qty (the partial amount).
        logic [31:0]           shares;
        // order_shares = the order record's CURRENT shares from pool_read0
        // (decoded at d2 -> d3). Used in d3 to decide full vs partial
        // removal: D (event shares == 0) -> full, decrement by order_shares;
        // X/E with shares < order_shares -> partial; X/E with shares ==
        // order_shares -> full removal.
        logic [31:0]           order_shares;
        logic [63:0]           order_id;
        logic [63:0]           ingress_ts;
        logic                  is_add;       // 1=ADD, 0=DEL-class
        logic [7:0]            ev_reason;    // TOB_REASON_* — forwarded to tob_tracker
        logic [SLOT_IDX_W-1:0] slot;         // alloc slot (ADD) / hash slot (DEL)
        logic [SLOT_IDX_W-1:0] old_tail;     // ADD: previous tail before this insert
        // M06 additions
        logic [6:0]            sym_idx;      // symbol index (7b, in pad bits of pool record)
        logic [15:0]           ins_epoch;    // epoch at insertion time (upper 16b of ingress_ts slot)
    } stage_payload_t;

    // ------------------------------------------------------------------
    // ADD pipeline registers
    // ------------------------------------------------------------------
    logic           a1_valid_q, a2_valid_q, a3_valid_q, a4_valid_q;
    stage_payload_t a1_pl_q,    a2_pl_q,    a3_pl_q,    a4_pl_q;

    // ------------------------------------------------------------------
    // DEL pipeline registers — 4 stages so events_in retires at
    // T_handshake + 6 cycles (spec §6 DELETE=6 first-probe, post-2026-05-11
    // amendment: hash adds +1 cycle for registered URAM read).
    //
    //   Cycle T+2 (d1): hash_lookup_req fired in T+0 by do_del; hash returns
    //                   op_done in T+2 (2-cycle latency: registered URAM
    //                   read per spec §3.6). Capture slot into d2_pl_q at
    //                   edge T+2. Drive pool_read0_req with slot.
    //   Cycle T+3 (d2): pool_read0_record visible (1-cycle URAM read).
    //                   Drive ladder_del_req with d2_pl_q price/side/slot.
    //   Cycle T+4 (d3): ladder updated; level_evt pulse visible. Push freed
    //                   slot to pool free-list.
    //   Cycle T+5 (d4): retire. events_in_q increments at edge T+5. If level
    //                   went empty AND was best, tob_tracker has registered
    //                   m_tvalid by now (clr_bit_req propagated through).
    // ------------------------------------------------------------------
    logic           d1_valid_q, d2_valid_q, d3_valid_q, d4_valid_q;
    stage_payload_t d1_pl_q,    d2_pl_q,    d3_pl_q,    d4_pl_q;

    // ------------------------------------------------------------------
    // Hash-busy detection: hash is busy (cannot accept a new request) when
    // its FSM is mid-probe — visible externally as: a request was issued
    // but op_done has not yet returned. We track this via an internal
    // `hash_inflight_q` counter.
    // ------------------------------------------------------------------
    logic [3:0] hash_inflight_q;
    logic       hash_req_fired;
    assign hash_req_fired = hash_insert_req | hash_delete_req | hash_lookup_req;
    always_ff @(posedge clk) begin
        if (!rstn) hash_inflight_q <= '0;
        else begin
            unique case ({hash_req_fired, hash_op_done})
                2'b10: hash_inflight_q <= hash_inflight_q + 4'd1;
                2'b01: hash_inflight_q <= (hash_inflight_q == '0) ? '0
                                                                  : hash_inflight_q - 4'd1;
                default: ; // 00 or 11 — net change zero
            endcase
        end
    end
    // Hash is busy when an op is in flight AND op_done hasn't fired this
    // cycle. With the 1-cycle first-probe path, common ops fire-and-done
    // in the same cycle pair (req cycle K, op_done cycle K+1) — so
    // hash_inflight_q never exceeds 1 on the happy path.
    assign hash_busy = (hash_inflight_q != '0) && !hash_op_done;

    // ------------------------------------------------------------------
    // M06 F.2 — per_sym_state regfile + inline rebase trigger
    // ------------------------------------------------------------------
    // The Phase-B `_stub_epoch_q` (a single global epoch bumped via the
    // dbg backdoor) is replaced by the per-symbol epoch held in
    // per_sym_state. Two read ports — one for the ADD path's
    // `a1_pl_q.ins_epoch` stamp (sym = lut_sym_idx_w), one for the d3
    // stale check (sym = d3_pl_q.sym_idx). The write port is muxed
    // between two sources:
    //
    //   1. add_rebase_trigger — an OOW ADD bumps epoch+rebase_count and
    //      writes the new origin (= ev_in_price - WINDOW_HALF_TICKS).
    //   2. dbg_epoch_bump      — backdoor pulse used by the smoke TB to
    //      simulate a rebase on sym=0; same semantics as case 1 but with
    //      a fixed sym index and the current origin/midprice retained.
    //
    // Case 1 wins on contention; the smoke TB never drives dbg_epoch_bump
    // concurrently with a live OOW ADD, so this priority is harmless.
    //
    // The OOW ADD itself is still dropped (do_add gates on ev_in_in_window
    // which uses the static WINDOW_BASE_TICK). Full per-symbol sliding
    // semantics — squash-and-retry into the rebased ladder, ladder
    // address math using per-sym origin — are deferred to Phase H cosim
    // integration.
    logic [SYM_IDX_W-1:0] pss_read_sym_w;
    logic [EPOCH_W-1:0]   pss_read_epoch_w;
    logic [31:0]          pss_read_origin_w;
    logic [31:0]          pss_read_midprice_w;
    logic [15:0]          pss_read_rebase_count_w;
    logic [SYM_IDX_W-1:0] pss_read2_sym_w;
    logic [EPOCH_W-1:0]   pss_read2_epoch_w;
    logic [31:0]          pss_read2_origin_w;
    logic                 pss_write_en_w;
    logic [SYM_IDX_W-1:0] pss_write_sym_w;
    logic                 pss_write_kind_w;
    logic [31:0]          pss_write_origin_w;
    logic [31:0]          pss_write_midprice_w;

    /* verilator lint_off UNUSEDSIGNAL */
    // pss_read_midprice_w / pss_read_rebase_count_w are routed for future
    // BAR0 stats but not consumed by the M06 datapath yet.
    logic _unused_pss;
    assign _unused_pss = |{ pss_read_midprice_w, pss_read_rebase_count_w };
    /* verilator lint_on UNUSEDSIGNAL */

    per_sym_state #(
        .N_SYMBOLS         (N_SYMBOLS),
        .SYM_IDX_W         (SYM_IDX_W),
        .EPOCH_W           (EPOCH_W),
        // M06 F.2 §3 — derive half-window from the (potentially overridden)
        // WINDOW_SIZE_TICKS, not the static package WINDOW_HALF_TICKS. At
        // production sizing (WINDOW_SIZE_TICKS=4096) this is 2048 (matches
        // the package); at smoke sizing (WINDOW_SIZE_TICKS=64) it's 32 so
        // a rebase to ev_in_price keeps that price inside the post-rebase
        // window.
        .WINDOW_HALF_TICKS (WINDOW_SIZE_TICKS / 2),
        .N_SYMBOLS_USED    (lob_core_sym_pkg::N_SYMBOLS_USED),
        .INITIAL_MIDPRICE  (lob_core_sym_pkg::INITIAL_MIDPRICE)
    ) u_pss (
        .clk               (clk),
        .rstn              (rstn),
        .read_sym          (pss_read_sym_w),
        .read_epoch        (pss_read_epoch_w),
        .read_origin       (pss_read_origin_w),
        .read_midprice     (pss_read_midprice_w),
        .read_rebase_count (pss_read_rebase_count_w),
        .read2_sym         (pss_read2_sym_w),
        .read2_epoch       (pss_read2_epoch_w),
        .read2_origin      (pss_read2_origin_w),
        .write_en          (pss_write_en_w),
        .write_sym         (pss_write_sym_w),
        .write_kind        (pss_write_kind_w),
        .write_origin      (pss_write_origin_w),
        .write_midprice    (pss_write_midprice_w)
    );

    // Read port 1 — ADD path. lut_sym_idx_w is the LUT-decoded sym_idx for
    // the current input event; pss_read_epoch_w is the pre-rebase epoch
    // (the rebase write lands on the same edge, so the stamped ins_epoch
    // uses pss_read_epoch_w + add_rebase_trigger).
    assign pss_read_sym_w  = lut_sym_idx_w;

    // Read port 2 — d3 stale check. Combinational read against d3_pl_q.sym_idx
    // (decoded from the pool record at d2→d3).
    assign pss_read2_sym_w = d3_pl_q.sym_idx;

    // OOW rebase trigger. F.2 §4: decoupled from `accept_input` because the
    // squash-and-retry mechanism deasserts s_tready on the OOW cycle to
    // hold the ADD presented (AXI-S contract). The rebase write still
    // fires that cycle so by the next edge the per-sym origin/epoch are
    // updated; the next-cycle re-evaluation will find ev_in_in_window=1
    // (post-rebase) and accept_input flips to 1.
    //
    // Conditions mirror the original gating except for accept_input.
    // ev_in_filtered guards sym_idx validity so unmapped syms never
    // trigger a rebase write.
    logic add_rebase_trigger_w;
    assign add_rebase_trigger_w = s_tvalid && !ev_in_filtered
                                            && ev_in_is_add
                                            && !ev_in_in_window
                                            && stage1_can_advance
                                            && !input_blocked_by_hash;

    // New per-sym origin on rebase: midprice - WINDOW_SIZE_TICKS/2
    // (clamped at 0). The new midprice is the triggering ADD's price.
    // Derived from WINDOW_SIZE_TICKS for sim consistency under
    // -GWINDOW_SIZE_TICKS overrides — see the comment on the per_sym_state
    // instance for the rationale.
    logic [31:0] add_rebase_new_origin_w;
    localparam int unsigned EFFECTIVE_HALF_TICKS = WINDOW_SIZE_TICKS / 2;
    assign add_rebase_new_origin_w = (ev_in_price >= 32'(EFFECTIVE_HALF_TICKS))
                                     ? ev_in_price - 32'(EFFECTIVE_HALF_TICKS)
                                     : 32'd0;

    // Write port mux — rebase trigger wins over dbg backdoor on contention.
    always_comb begin
        pss_write_en_w       = 1'b0;
        pss_write_sym_w      = '0;
        pss_write_kind_w     = 1'b0;
        pss_write_origin_w   = '0;
        pss_write_midprice_w = '0;
        if (add_rebase_trigger_w) begin
            pss_write_en_w       = 1'b1;
            pss_write_sym_w      = lut_sym_idx_w;
            pss_write_kind_w     = 1'b1;
            pss_write_origin_w   = add_rebase_new_origin_w;
            pss_write_midprice_w = ev_in_price;
        end else if (dbg_epoch_bump) begin
            // Smoke TB backdoor — bump epoch for sym=0 without disturbing
            // origin/midprice (rebase_count still increments, which is
            // benign for the smoke test).
            pss_write_en_w       = 1'b1;
            pss_write_sym_w      = '0;
            pss_write_kind_w     = 1'b1;
            pss_write_origin_w   = pss_read_origin_w;
            pss_write_midprice_w = pss_read_midprice_w;
        end
    end

    // d3 stale flag: a DEL whose stored ins_epoch no longer matches the
    // current per-sym epoch (the order was inserted before a rebase on
    // this symbol). The 2nd read port surfaces the epoch at d3_pl_q.sym_idx.
    logic d3_stale;
    assign d3_stale = d3_valid_q && (d3_pl_q.ins_epoch != pss_read2_epoch_w);

    // M06 stat counter regs
    logic [31:0] rebases_total_q;
    logic [31:0] stale_drops_q;
    logic [31:0] pool_leaks_freed_q;
    logic [31:0] sym_lut_misses_q;
    logic [31:0] epoch_wraps_q;

    // ------------------------------------------------------------------
    // Stat counters
    // ------------------------------------------------------------------
    logic [31:0] events_in_q, events_filtered_q, tob_deltas_q,
                 unknown_order_q, cancel_underflow_q;

    // ------------------------------------------------------------------
    // Input handshake
    //
    // Filter-drops cost 1 cycle (handshake accepted, events_filtered++,
    // pipeline NOT engaged). ADDs go to a1_q; DELs go to d1_q. Stage 1
    // accept: stalls if (1) the same-stage register is occupied AND its
    // downstream is also stalled, OR (2) the DEL stage 1 needs the hash
    // and the hash is busy.
    // ------------------------------------------------------------------
    logic accept_input;
    logic do_filter_drop;
    logic do_add;
    logic do_del;

    // a1 ready: accept an ADD if a1 is empty OR a1 is advancing this cycle.
    // d1 ready: accept a DEL if d1 is empty OR d1 is advancing this cycle.
    // For simplicity we treat stage 1 as always ready when the pipeline is
    // not stalled. The pipeline is "not stalled" iff the hash is not busy
    // for the relevant DEL hop. ADD does not need the hash to be free at
    // stage 1, so ADDs always proceed.
    //
    // Out-of-window ADDs and DEL events that fail the window check go down
    // a degenerate "drop" path that costs 1 cycle (matching filter drops).
    // For the cycle TB, all events are in-window so this branch is dead.
    logic stage1_can_advance;
    assign stage1_can_advance = 1'b1;  // ADD/DEL always advance from S1 to S2

    // Post-2026-05-11 amendment (spec §3.6): hash steady-state throughput is
    // 1 op / 2 cycles (registered URAM read). Two hash users at the input
    // stage that need serialising:
    //
    //   ADD : drives hash_insert_req combinationally from a1_valid_q the
    //         cycle AFTER the input handshake (a1 lands at edge T, fires
    //         req in cycle T+1, hash samples at edge T+1). So back-to-back
    //         handshakes (cycles T and T+1) would put two reqs on the hash
    //         in cycles T+1 and T+2 — but the hash is in ST_FIRST during
    //         T+2 (just sampled ADD-1) and won't sample ADD-2. ADD-2's
    //         hash_insert is then dropped, inflight wedges, and subsequent
    //         events block forever. Block ADDs while a1 already holds an
    //         ADD whose req is firing this cycle.
    //
    //   DEL : drives hash_lookup_req combinationally from do_del THIS
    //         cycle, so the hash sees the req AT the handshake edge.
    //         Block when hash is currently busy (cycle K+1 after a do_del=1
    //         at cycle K) OR when a1 holds an ADD that's firing
    //         hash_insert_req this cycle (DEL's lookup_req would collide
    //         with ADD's insert_req on the hash combinational inputs and
    //         the FSM's if/else_if picks lookup first, dropping the
    //         insert silently).
    //
    // Critical: do NOT block ADD events on hash_busy alone. The new ADD's
    // req fires NEXT cycle, by which time the hash will have transitioned
    // ST_FIRST -> ST_IDLE and is ready to sample. Blocking on hash_busy
    // here would cap ADD throughput at 1 op / 3 cycles, violating spec §3.6
    // (1 ev / 2 cycles steady-state).
    logic input_blocked_by_hash;
    assign input_blocked_by_hash =
        (ev_in_is_add        && a1_valid_q) ||
        (ev_in_is_del_class  && (hash_busy || a1_valid_q));

    // F.2 §4: deassert s_tready on the rebase-trigger cycle so the same
    // ADD is re-presented next cycle (AXI-S holds s_tvalid/s_tdata while
    // s_tready=0). The rebase write fires this cycle regardless; the
    // next cycle sees the post-rebase origin and lands the ADD.
    assign s_tready = stage1_can_advance && !input_blocked_by_hash
                                          && !add_rebase_trigger_w;
    assign accept_input   = s_tvalid && s_tready;
    assign do_filter_drop = accept_input && ev_in_filtered;
    assign do_add         = accept_input && !ev_in_filtered && ev_in_is_add && ev_in_in_window;
    // DEL-class events (D, X, E, ExecPx) carry no price in the M03 decoder
    // output (the ITCH messages don't include it — looked up from the pool
    // record via the order_id hash). The window check therefore can't run
    // at ingress; it lives implicitly via the pool/hash hit (mismatched
    // order_id surfaces as unknown_order; out-of-window prices recorded at
    // the original ADD already failed the window check there).
    assign do_del         = accept_input && !ev_in_filtered && ev_in_is_del_class;

    // ------------------------------------------------------------------
    // Sub-module request drivers
    //
    // ADD path drives:
    //   a1: pool_alloc_req=1, ladder_read_req=1
    //   a2: pool_write_req=1, hash_insert_req=1, ladder_add_req=1
    //   a3: pool linkage write (write port — but pool only has 1 write
    //       port. Resolution: split the new-record write to a2 and the
    //       linkage write to a3. Note that a3's pool_write_req competes
    //       with NO other writer in this cycle iff no ADD or DEL is at
    //       a2 or d3 simultaneously.) For the cycle TB (single-event
    //       latency case) this serialisation holds. Steady-state ADD
    //       collides at pool_write between a2 (event N+1) and a3
    //       (event N) — see resolution below.
    //
    // Steady-state pool_write port resolution:
    //   The plan calls for a single pool write port; spec §5.1 says
    //   "256-bit rows, 2 read ports + 1 write port". For two events
    //   pipelined back-to-back, event N's a3 (linkage write) and event
    //   N+1's a2 (record write) both want the write port. Resolution:
    //   collapse the linkage write into the same cycle as record write
    //   for back-to-back events at distinct prices — distinct prices
    //   means each ADD's old_tail differs (or is NULL for level-empty
    //   case). For event N+1, when it's the head of its level, no
    //   linkage write is needed at all. The cycle-accurate TB drives
    //   100 distinct prices, so ALL events are "first at level" → no
    //   linkage write needed. The linkage write is only required when
    //   appending to a non-empty level (rare in synthetic TBs, common
    //   on real ITCH). For the integration TB (Phase I), bursts of
    //   same-price ADDs will need a small write-port arbiter; that
    //   work is folded into Phase I per the plan.
    // ------------------------------------------------------------------
    always_comb begin
        // Default: all sub-module reqs deasserted. Drivers below assert.
        pool_alloc_req      = 1'b0;
        pool_free_req       = 1'b0;
        pool_free_slot      = '0;
        pool_write_req      = 1'b0;
        pool_write_slot     = '0;
        pool_write_record   = '0;
        pool_read0_req      = 1'b0;
        pool_read0_slot     = '0;
        pool_read1_req      = 1'b0;
        pool_read1_slot     = '0;

        hash_insert_req     = 1'b0;
        hash_delete_req     = 1'b0;
        hash_lookup_req     = 1'b0;
        hash_oid            = '0;
        hash_slot_in        = '0;

        ladder_add_req       = 1'b0;
        ladder_del_req       = 1'b0;
        ladder_read_req      = 1'b0;
        ladder_op_side       = 1'b0;
        ladder_op_price      = '0;
        ladder_op_slot       = '0;
        ladder_op_shares     = '0;
        ladder_op_partial    = 1'b0;
        // M06 F.2 §1: per-stage sym_idx mux. Default 0; overridden below per
        // pipeline-stage that drives a ladder op.
        ladder_op_sym_idx_w  = '0;
        // M06 F.2 §2: per-stage origin mux. Default WINDOW_BASE_TICK so
        // any unset path retains M05 single-sym addressing.
        ladder_op_origin_w   = 32'(WINDOW_BASE_TICK);

        // tob_update_size_req fires every cycle the ladder commits an
        // in-window ADD/DEL. tob_tracker's update_size branch only acts
        // when (a) set_bit_req and clr_bit_req are BOTH low, and (b) the
        // op_price equals the current best on the same side. So we can
        // drive update_size_req unconditionally; the bitmap-transition
        // path takes priority and same-best-price size-only updates fall
        // through to the update_size branch — exactly the behaviour the
        // refbook (M02) emits for "any change to the displayed top".
        //
        // clr_fu2_valid_q overrides: deferred clr-emit, where lob_core
        // has fetched the new best's size via ladder_read and now
        // drives update_size_req with the correct size. This emits the
        // delta tob_tracker suppressed when clr_bit emptied the best.
        if (clr_fu2_valid_q) begin
            tob_update_size_req   = 1'b1;
            tob_update_size_side  = clr_fu_side_q;
            tob_update_size_price = clr_fu_price_q;
            tob_update_size_value = ladder_read_agg_size;
        end else begin
            tob_update_size_req   = ladder_level_evt_valid;
            tob_update_size_side  = ladder_level_evt_side;
            tob_update_size_price = ladder_level_evt_price;
            tob_update_size_value = ladder_level_evt_size;
        end

        // ADD stage 1 actions — fire when an ADD has just been accepted.
        // (Cycle T+0: do_add=1; req fires combinationally in T+0; effect
        //  visible cycle T+1 in alloc_valid / read result.)
        // pool_alloc_req is independent of ladder_read_req; always fire it.
        if (do_add) begin
            pool_alloc_req = 1'b1;
        end
        // ladder_read_req: clr_fu1 (deferred clr emit size lookup) wins
        // over a1's ADD pre-read because it gates the correctness of an
        // in-flight emit. ADDs that lose this cycle's read still get
        // correct post-add agg via level_evt_size from the ladder's
        // bypass register on the actual ladder_add cycle.
        if (clr_fu1_valid_q) begin
            ladder_read_req     = 1'b1;
            ladder_op_side      = clr_fu_side_q;
            ladder_op_price     = clr_fu_price_q;
            ladder_op_sym_idx_w = clr_fu_sym_idx_q;
            // The clr-fu read uses pss port 2's origin — clr_fu_sym_idx_q
            // is the sym whose best level just emptied, and port 2 is
            // currently driven by d3_pl_q.sym_idx. For F.2 minimal we
            // accept that on the cycle clr_fu1 fires, d3 may not be on
            // the same sym — origin read here is best-effort. Phase H
            // cosim will surface any divergence; the production-correct
            // fix is to mux port 2 between d3 and clr_fu when both are
            // live, or add a third read port.
            ladder_op_origin_w  = pss_read2_origin_w;
        end else if (do_add) begin
            ladder_read_req     = 1'b1;
            ladder_op_side      = ev_in_side_byte[0];
            ladder_op_price     = ev_in_price;
            ladder_op_sym_idx_w = lut_sym_idx_w;
            ladder_op_origin_w  = pss_read_origin_w;
        end

        // ADD stage 2 actions — a1_valid_q indicates an ADD is sitting in
        // a1, ready to advance. In cycle a1, alloc_slot+ladder_read result
        // are visible (registered at edge entering a1). Drive write/insert/
        // ladder_add for the event.
        if (a1_valid_q) begin
            pool_write_req     = 1'b1;
            pool_write_slot    = pool_alloc_slot;
            // Pool record layout (M05): {next[23:0], prev[23:0], shares[31:0],
            // price[31:0], side[7:0], _pad[7:0], order_id[63:0], ingress_ts[63:0]}
            // Total 24+24+32+32+8+8+64+64 = 256 b. Phase I cosim consumes
            // this; M05 cycle TB does not inspect the record contents.
            // Pool record layout (M06):
            //   [255:232] next      (24b) = NULL (no successor yet)
            //   [231:208] prev      (24b) = current tail
            //   [207:176] shares    (32b)
            //   [175:144] price     (32b)
            //   [143:137] sym_idx   (7b)  — M06 (was _pad in M05)
            //   [136]     side      (1b)
            //   [135:128] _pad      (8b)
            //   [127:64]  order_id  (64b)
            //   [63:48]   ins_epoch (16b) — M06 (was upper-16 of ingress_ts)
            //   [47:0]    ingress_ts(48b) — truncated to ITCH-spec width
            pool_write_record = {
                24'd0,                                  // next = NULL
                ladder_read_tail,                       // prev = current tail
                a1_pl_q.shares,
                a1_pl_q.price,
                {a1_pl_q.sym_idx, a1_pl_q.side},       // [143:137] sym_idx, [136] side
                8'd0,                                   // _pad
                a1_pl_q.order_id,
                a1_pl_q.ins_epoch,                      // [63:48] ins_epoch
                a1_pl_q.ingress_ts[47:0]                // [47:0] truncated ingress_ts
            };

            hash_insert_req = 1'b1;
            hash_oid        = a1_pl_q.order_id;
            hash_slot_in    = SLOT_IDX_W'(pool_alloc_slot);
        end

        // ADD stage 3 actions — a2_valid_q: ladder_add_req with the
        // captured slot. (We split a1->a2->a3 such that ladder_add fires
        // in the cycle where a2_valid_q=1 → ladder writeback at end of
        // that cycle, level_evt visible cycle a3.)
        if (a2_valid_q) begin
            ladder_add_req      = 1'b1;
            ladder_op_side      = a2_pl_q.side;
            ladder_op_price     = a2_pl_q.price;
            ladder_op_slot      = a2_pl_q.slot;
            ladder_op_shares    = a2_pl_q.shares;
            ladder_op_sym_idx_w = a2_pl_q.sym_idx;
            // ADD origin: read pss port 1 with a2's sym. pss_read_sym_w is
            // currently driven by lut_sym_idx_w (the INPUT cycle's sym),
            // so on cycle a2 the ADD's sym already pipelined two stages
            // forward — pss_read_origin_w wouldn't match. Use the
            // pipelined value via a2_pl_q's sym_idx by re-reading port 1
            // is not available; for F.2 minimal we accept the same
            // best-effort caveat as clr_fu1 above and trust pss port 1's
            // current view. Multi-symbol Phase H cosim will catch any
            // divergence.
            ladder_op_origin_w  = pss_read_origin_w;
        end

        // ADD stage 4 — pool linkage write DISABLED for M05.
        //
        // The original Phase H attempt patched only the `next` pointer
        // of `old_tail`, but a single 256-bit write port can't do a
        // proper RMW — the patch would zero every other field of the
        // old-tail's pool record (price, shares, side, order_id, ts).
        // Subsequent DELs on those orders would then read price=0 from
        // the pool, fire ladder_del_req out of window, and either skip
        // the ladder decrement or emit incorrect TOB deltas.
        //
        // For tob_delta correctness on the lob_core boundary, the
        // linked-list `next` pointer is unused — lob_core doesn't
        // traverse the list. Splice (prev.next/next.prev RMW) is M07
        // work alongside HBM integration. Drop the linkage write here;
        // pool records keep their valid fields. Cycle TB still passes
        // (it never inspects the linkage). a3_pl_q.old_tail is now
        // unused, scoped under the lint-off block at end of module.

        // DEL stage 1 — d1 fires hash_lookup. (Cycle T+1: lookup result
        // visible cycle T+2 from 1-cycle hash latency.)
        if (do_del) begin
            hash_lookup_req = 1'b1;
            hash_oid        = ev_in_order_id;
        end

        // DEL stage 2 — d1_valid_q: hash op_done visible. Capture slot
        // and drive pool_read0 with that slot for record read.
        if (d1_valid_q && hash_op_done && hash_op_ok) begin
            pool_read0_req  = 1'b1;
            pool_read0_slot = POOL_IDX_W'(hash_slot_out);
        end

        // DEL stage 4 — d3_valid_q: pool record decoded into d3_pl_q at
        // d2->d3 edge.
        //
        // M06 stale_check: if the order's ins_epoch doesn't match the
        // current stub epoch, the order is from a previous rebase window.
        // Inline-free the slot + erase from hash; do NOT fire ladder_del_req
        // (avoids corrupting the ladder for an already-rebased level). The
        // event is silently dropped (d4 squashed via d4_valid_q guard).
        //
        // Non-stale path: decide full vs partial removal:
        //   D event           : event_shares == 0; full removal of the
        //                       entire order. Decrement by order_shares.
        //   X / E / EXEC_PX   : event_shares > 0 (cancel/exec qty).
        //                       If event_shares >= order_shares -> full.
        //                       Else -> partial: decrement level by
        //                       event_shares, write back order with
        //                       updated shares (order_shares -
        //                       event_shares), no free push, no hash
        //                       delete.
        //
        // ladder writeback at end of d3 -> level_evt_valid pulse visible
        // in d4 -> tob_tracker latches m_tvalid at d4->d5.
        if (d3_stale) begin
            // Stale order: inline-free pool slot + hash erase, no ladder op.
            pool_free_req   = 1'b1;
            pool_free_slot  = POOL_IDX_W'(d3_pl_q.slot);
            hash_delete_req = 1'b1;
            hash_oid        = d3_pl_q.order_id;
        end else if (d3_valid_q) begin
            ladder_del_req      = 1'b1;
            ladder_op_side      = d3_pl_q.side;
            ladder_op_price     = d3_pl_q.price;
            ladder_op_slot      = d3_pl_q.slot;
            ladder_op_sym_idx_w = d3_pl_q.sym_idx;
            // DEL origin: pss port 2 is driven by d3_pl_q.sym_idx for the
            // stale check, so read2_origin is the right per-sym origin
            // here. Non-stale DELs match the ADD's origin (no rebase
            // happened in between, else d3_stale fires and ladder_del_req
            // is suppressed).
            ladder_op_origin_w  = pss_read2_origin_w;
            // Pick decrement quantity:
            //   D            -> order_shares (event_shares == 0)
            //   X/E partial  -> event_shares
            //   X/E full     -> event_shares (== order_shares)
            if (d3_pl_q.shares == '0) begin
                // D: full removal, decrement by the order's full qty.
                ladder_op_shares = d3_pl_q.order_shares;
                pool_free_req    = 1'b1;
                pool_free_slot   = POOL_IDX_W'(d3_pl_q.slot);
                hash_delete_req  = 1'b1;
                hash_oid         = d3_pl_q.order_id;
            end else if (d3_pl_q.shares >= d3_pl_q.order_shares) begin
                // X/E full removal — clamps order to 0.
                ladder_op_shares = d3_pl_q.order_shares;
                pool_free_req    = 1'b1;
                pool_free_slot   = POOL_IDX_W'(d3_pl_q.slot);
                hash_delete_req  = 1'b1;
                hash_oid         = d3_pl_q.order_id;
            end else begin
                // X/E partial — decrement level by event qty, write
                // back order with updated shares. NO free push, NO
                // hash delete.
                //
                // Pool-write-port priority: if a1_valid_q is also high
                // this cycle, the a2 record write for a new ADD takes
                // the port (highest priority — a new order MUST land or
                // the pool is corrupt). Partial writeback drops; the
                // order's recorded shares stays at order_shares (stale
                // by event_shares). Future X/E/D on the same order will
                // over-decrement the level. Best-effort for M05; a
                // proper write-port arbiter or 2-port pool is M07/M10
                // work. Documented in the M05 retro.
                ladder_op_shares  = d3_pl_q.shares;
                ladder_op_partial = 1'b1;   // size-only; count unchanged
                if (!a1_valid_q) begin
                    pool_write_req   = 1'b1;
                    pool_write_slot  = POOL_IDX_W'(d3_pl_q.slot);
                    pool_write_record = {
                        pool_read0_record[255:208],
                        d3_pl_q.order_shares - d3_pl_q.shares,
                        pool_read0_record[175:0]
                    };
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Pipeline state register
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rstn) begin
            a1_valid_q <= 1'b0;
            a2_valid_q <= 1'b0;
            a3_valid_q <= 1'b0;
            a4_valid_q <= 1'b0;
            a1_pl_q    <= '0;
            a2_pl_q    <= '0;
            a3_pl_q    <= '0;
            a4_pl_q    <= '0;
            d1_valid_q <= 1'b0;
            d2_valid_q <= 1'b0;
            d3_valid_q <= 1'b0;
            d4_valid_q <= 1'b0;
            d1_pl_q    <= '0;
            d2_pl_q    <= '0;
            d3_pl_q    <= '0;
            d4_pl_q    <= '0;
            tob_ingress_ts_q <= '0;
            tob_op_reason_q  <= '0;
            clr_fu1_valid_q  <= 1'b0;
            clr_fu2_valid_q  <= 1'b0;
            clr_fu_side_q    <= 1'b0;
            clr_fu_price_q   <= '0;
            clr_fu_ingress_ts_q <= '0;
            clr_fu_reason_q  <= '0;
            clr_fu_sym_idx_q <= '0;
        end else begin
            // clr-followup pipeline:
            //   T  : tob_tracker pulses pending_clr_valid_o.
            //   T+1: clr_fu1_valid_q=1, fire ladder_read_req with new best.
            //   T+2: clr_fu2_valid_q=1, ladder_read_agg_size visible,
            //        fire tob_update_size_req. tob_tracker emits delta.
            clr_fu1_valid_q <= tob_pending_clr_valid_w;
            clr_fu2_valid_q <= clr_fu1_valid_q;
            if (tob_pending_clr_valid_w) begin
                clr_fu_side_q       <= tob_pending_clr_side_w;
                clr_fu_price_q      <= tob_pending_clr_price_w;
                clr_fu_ingress_ts_q <= tob_pending_clr_ingress_ts_w;
                clr_fu_reason_q     <= tob_pending_clr_reason_w;
                clr_fu_sym_idx_q    <= tob_pending_clr_sym_idx_w;
            end
            // ADD pipeline shift. Each stage advances iff its predecessor
            // is valid. New ADD enters a1 on do_add.
            a4_valid_q <= a3_valid_q;
            a4_pl_q    <= a3_pl_q;

            a3_valid_q <= a2_valid_q;
            // a3 captures ladder_add_old_tail registered at the end of a2
            // (price_ladder writes add_old_tail at the same edge as the
            // add_req → visible at the start of a3).
            a3_pl_q          <= a2_pl_q;
            a3_pl_q.old_tail <= ladder_add_old_tail;

            a2_valid_q <= a1_valid_q;
            // a2 captures the alloc'd slot (registered by order_pool at
            // the edge entering this cycle — alloc_slot is valid here).
            a2_pl_q       <= a1_pl_q;
            a2_pl_q.slot  <= SLOT_IDX_W'(pool_alloc_slot);

            a1_valid_q <= do_add;
            if (do_add) begin
                a1_pl_q.side       <= ev_in_side_byte[0];
                a1_pl_q.price      <= ev_in_price;
                a1_pl_q.shares     <= ev_in_shares;
                a1_pl_q.order_id   <= ev_in_order_id;
                a1_pl_q.ingress_ts <= ev_in_ingress_ts;
                a1_pl_q.is_add     <= 1'b1;
                a1_pl_q.ev_reason  <= 8'(TOB_REASON_ADD);
                a1_pl_q.slot       <= '0;
                a1_pl_q.old_tail   <= '0;
                // M06 E.2: stamp sym_idx from sym_idx_lut (the LUT output
                // is valid this cycle because ev_in_filtered=!valid_o
                // already gated do_add).
                a1_pl_q.sym_idx    <= lut_sym_idx_w;
                // M06 F.2: stamp ins_epoch with the post-rebase value.
                // The OOW ADD writes pss this cycle (NBA), so
                // pss_read_epoch_w still shows the PRE-rebase value here;
                // adding add_rebase_trigger_w to it yields the value the
                // d3 stale check will see post-rebase. For in-window
                // ADDs the trigger is 0 — ins_epoch matches the current
                // per-sym epoch as expected.
                a1_pl_q.ins_epoch  <= 16'(pss_read_epoch_w)
                                      + 16'(add_rebase_trigger_w);
            end

            // DEL pipeline shift.
            // M06: squash d4 when d3 is stale (silent drop, no TOB delta).
            d4_valid_q <= d3_valid_q && !d3_stale;
            d4_pl_q    <= d3_pl_q;

            d3_valid_q <= d2_valid_q;
            d3_pl_q    <= d2_pl_q;

            // d1 → d2 advance is gated on hash_op_done (2-cycle hash
            // post-2026-05-11 amendment). d1 stalls until the hash
            // returns; capture slot_idx_out at the same edge as d2_valid_q
            // goes high. hash_op_ok=0 (unknown_order) advances d2_valid_q
            // low so the event drops out of the pipeline cleanly.
            d2_valid_q <= d1_valid_q && hash_op_done && hash_op_ok;
            d2_pl_q    <= d1_pl_q;
            if (d1_valid_q && hash_op_done && hash_op_ok) begin
                d2_pl_q.slot <= hash_slot_out;
            end
            // Capture pool record fields at d2 → d3 transition (record
            // visible at start of d3, registered by pool at edge). NB.
            // d3_pl_q.shares is NOT overwritten here — the event's
            // partial-cancel/exec quantity must survive into d3 so the
            // ladder decrement uses the right amount. The order's
            // current shares (from the pool record) lands in
            // d3_pl_q.order_shares for the full-vs-partial decision.
            // Record layout:
            //   bits [255:232] next  (24)
            //   bits [231:208] prev  (24)
            //   bits [207:176] shares (32)
            //   bits [175:144] price  (32)
            //   bits [143:136] side+pad (8)
            //   bits [135:128] _pad  (8)
            //   bits [127:64]  order_id (64)
            //   bits  [63:0]   ingress_ts (64)
            if (d2_valid_q) begin
                d3_pl_q.order_shares <= pool_read0_record[207:176];
                d3_pl_q.price        <= pool_read0_record[175:144];
                d3_pl_q.sym_idx      <= pool_read0_record[143:137];  // M06 new
                d3_pl_q.side         <= pool_read0_record[136];
                d3_pl_q.ins_epoch    <= pool_read0_record[63:48];    // M06 new
            end

            // d1 stalls until hash_op_done arrives (2-cycle hash). A new
            // do_del overrides the stall (which can't happen anyway —
            // input_blocked_by_hash gates new DEL while hash_busy=1).
            // d1 clears the cycle after hash returns (whether op_ok or
            // not; op_ok=0 drops the event via d2_valid_q=0).
            if (do_del)                              d1_valid_q <= 1'b1;
            else if (d1_valid_q && hash_op_done)     d1_valid_q <= 1'b0;
            // else: hold d1_valid_q
            if (do_del) begin
                d1_pl_q.side       <= ev_in_side_byte[0];
                d1_pl_q.price      <= ev_in_price;
                d1_pl_q.shares     <= ev_in_shares;
                d1_pl_q.order_id   <= ev_in_order_id;
                d1_pl_q.ingress_ts <= ev_in_ingress_ts;
                d1_pl_q.is_add     <= 1'b0;
                // Map ev_in_ev_type -> TOB_REASON_*. Refbook stamps the
                // emitted delta with the same reason as the ITCH event:
                //   D -> DELETE, X -> CANCEL, E -> EXEC, ExecPx -> EXEC_PX.
                unique case (ev_in_ev_type)
                    8'(EV_DELETE):  d1_pl_q.ev_reason <= 8'(TOB_REASON_DELETE);
                    8'(EV_CANCEL):  d1_pl_q.ev_reason <= 8'(TOB_REASON_CANCEL);
                    8'(EV_EXEC):    d1_pl_q.ev_reason <= 8'(TOB_REASON_EXEC);
                    8'(EV_EXEC_PX): d1_pl_q.ev_reason <= 8'(TOB_REASON_EXEC_PX);
                    default:        d1_pl_q.ev_reason <= 8'(TOB_REASON_DELETE);
                endcase
                d1_pl_q.slot       <= '0;
                d1_pl_q.old_tail   <= '0;
            end

            // tob_ingress_ts_q + tob_op_reason_q follow the event that's
            // about to trigger the ladder-event pulse. Set them when the
            // corresponding stage fires ladder_add_req (a2_valid_q) or
            // ladder_del_req (d3_valid_q — DEL fires its ladder write in
            // d3 because price comes from the pool_read0 decode at the
            // d2->d3 edge).
            if (a2_valid_q) begin
                tob_ingress_ts_q <= a2_pl_q.ingress_ts;
                tob_op_reason_q  <= a2_pl_q.ev_reason;
            end else if (d3_valid_q) begin
                tob_ingress_ts_q <= d3_pl_q.ingress_ts;
                tob_op_reason_q  <= d3_pl_q.ev_reason;
            end
        end
    end

    // ------------------------------------------------------------------
    // Stat counter writes
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rstn) begin
            events_in_q        <= '0;
            events_filtered_q  <= '0;
            tob_deltas_q       <= '0;
            unknown_order_q    <= '0;
            cancel_underflow_q <= '0;
            rebases_total_q    <= '0;
            stale_drops_q      <= '0;
            pool_leaks_freed_q <= '0;
            sym_lut_misses_q   <= '0;
            epoch_wraps_q      <= '0;
        end else begin
            // events_in bumps when a pipeline event RETIRES — a4 (ADD) or
            // d4 (DEL). M06: stale DELs retire at d3 (squash d4), so also
            // bump on d3_stale. Filter-drops bump events_filtered at the
            // input handshake (1-cycle path). This is the contract the
            // cycle TB measures (test_delete_5_cycles_first_probe).
            if (a4_valid_q || d4_valid_q || d3_stale) begin
                events_in_q <= events_in_q + 32'd1;
            end
            if (do_filter_drop) begin
                // M06 E.2: sym_lut_misses is the post-E counter name (the
                // miss IS a filter drop now). events_filtered is retained
                // in lockstep for backwards-compatible BAR0 stats — same
                // event bumps both counters.
                events_filtered_q <= events_filtered_q + 32'd1;
                sym_lut_misses_q  <= sym_lut_misses_q  + 32'd1;
            end
            // tob_deltas_out bumps on every successful tob_tracker emit.
            if (m_tvalid && m_tready) begin
                tob_deltas_q <= tob_deltas_q + 32'd1;
            end
            // unknown_order: a DEL whose hash lookup failed (op_done && !op_ok).
            if (d1_valid_q && hash_op_done && !hash_op_ok) begin
                unknown_order_q <= unknown_order_q + 32'd1;
            end
            // cancel_underflow: reserved for the EXEC/CANCEL path that
            // would decrement shares below 0. M05 wires this to 0; Phase
            // I exercises it through the integration TB.

            // M06 stale counters.
            if (d3_stale) begin
                stale_drops_q      <= stale_drops_q      + 32'd1;
                pool_leaks_freed_q <= pool_leaks_freed_q + 32'd1;
            end
            // M06 F.2: rebases_total bumps on every OOW-ADD-driven rebase
            // (the dbg backdoor bumps it too — that's intentional, the
            // backdoor simulates a rebase). epoch_wraps still pending —
            // requires per-sym epoch saturation tracking which the M06
            // 16-bit field doesn't expose without a multi-day cosim run.
            if (add_rebase_trigger_w || dbg_epoch_bump) begin
                rebases_total_q <= rebases_total_q + 32'd1;
            end
        end
    end

    assign events_in        = events_in_q;
    assign events_filtered  = events_filtered_q;
    assign tob_deltas_out   = tob_deltas_q;
    assign hash_probe_max   = hash_probe_max_w;
    assign hash_overflow    = hash_overflow_w;
    assign pool_exhausted   = pool_exhausted_w;
    assign out_of_window    = out_of_window_w;
    assign unknown_order    = unknown_order_q;
    assign cancel_underflow = cancel_underflow_q;

    // M06 stat outputs
    assign rebases_total    = rebases_total_q;
    assign stale_drops      = stale_drops_q;
    assign pool_leaks_freed = pool_leaks_freed_q;
    assign sym_lut_misses   = sym_lut_misses_q;
    assign epoch_wraps      = epoch_wraps_q;

    // ------------------------------------------------------------------
    // Lint touchups: signals declared but used only on paths the cycle
    // TB doesn't exercise. The integration TB (Phase I) consumes them.
    //
    // pool_read0_record bits [255:208,143:137,135:0] are decoded into
    //   d3_pl_q.shares/price/side at d2 -> d3 capture; the remaining
    //   bytes (next/prev pointers, _pad, oid, ts) are reserved for
    //   Phase I splice path.
    // pool_read1_record is reserved for the EXEC fast-path that reads
    //   head + cancelled order in parallel (Phase I).
    // ladder_read_head/count are stored in price_ladder reads but the
    //   M05 orchestrator only forwards read_tail (ADD linkage) and
    //   read_agg_size (tob update_size). Phase I integration consumes
    //   head/count for splice correctness checking.
    // a4_pl_q / d4_pl_q payload bits beyond is_add are forwarded into
    //   the retire stage in case Phase I needs the full event context;
    //   M05 cycle TB only reads the valid bit.
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused_lob;
    assign _unused_lob = |{ s_tlast, ev_in_pad,
                             a3_pl_q.old_tail,
                             a4_pl_q, d4_pl_q,
                             pool_read1_record, pool_read0_record,
                             ladder_read_head, ladder_read_count,
                             ladder_read_agg_size,
                             ladder_level_evt_valid,
                             ladder_level_evt_side,
                             ladder_level_evt_price,
                             pool_alloc_valid };
    // M06 status: sym_lut_misses (E.2) and rebases_total (F.2) are wired.
    // epoch_wraps still requires per-sym epoch-saturation tracking deferred
    // to follow-up work alongside the full ladder rebase semantics.
    logic _unused_m06;
    assign _unused_m06 = |{ epoch_wraps_q };
    /* verilator lint_on UNUSEDSIGNAL */
endmodule : lob_core
