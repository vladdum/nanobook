// SPDX-License-Identifier: Apache-2.0
// order_id_hash — open-addressing hash table for order_id -> slot_idx.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (top-level dataflow), §3.3 step 1 (DELETE pipeline cycle 1),
//   §5.1 (URAM sizing), §5.3 (hash function selection),
//   §6 (cycle targets — DELETE = 5 first-probe).
// Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 16.
//
// Behaviour:
//   - HASH_SLOTS rows of {valid, tombstone, _pad, order_id (64), slot_idx (24)}
//     packed to 128-bit URAM row (2 URAMs wide).
//   - Linear probing up to MAX_PROBE_DEPTH probes.
//   - hash_probe_max saturates to the deepest probe ever observed.
//   - hash_overflow increments when an insert/lookup exceeds MAX_PROBE_DEPTH.
//   - Hash function selected at Phase B via lob_core_params_pkg::HASH_FN.
//     Phase B pinned HASH_XORSHIFT64; CRC32 path is a $fatal stub.
//
// 2026-05-11 amendment — registered first-probe BUCKET INDEX:
//   The original 1-state ST_IDLE performed table_ram[first_idx] as a
//   combinational read in the same cycle the request was sampled. This
//   created an 18-logic-level critical path from price_ladder.shares ->
//   orchestrator decide -> hash64() -> bucket decode -> row write-CE,
//   missing 250 MHz by WNS = -0.705 ns at HASH_SLOTS=1024 (2026-05-10
//   OOC synth). The long chain was the HASH and bucket decode upstream
//   of the URAM read, not the URAM read itself.
//
//   Amended FSM (3 states): ST_IDLE samples req and registers first_idx
//   into first_idx_q; ST_FIRST decided hit/miss using row_first
//   (combinational read of table_ram[first_idx_q]); ST_PROBE continued
//   multi-probe traversal with the same combinational read pattern
//   (row_at_probe tracked table_ram[probe_idx]).
//
//   Spec authority: docs/superpowers/specs/2026-05-09-nanobook-m05-book-
//   core-uram-design.md §3.6 (2026-05-11 amendment).
//
// 2026-05-13 amendment — registered URAM PAYLOAD READ:
//   The 2026-05-11 amendment registered the bucket INDEX before the URAM
//   read; the payload read itself stayed combinational on the already-
//   registered first_idx_q / probe_idx. Vivado infers UltraRAM only when
//   the data port is also registered, so the table_ram array still fell
//   back to flip-flops at the smoke config (it was the second-largest
//   FF source in the M06 Phase J OOC synth, after price_ladder.levels).
//
//   The FSM now reads the payload through dedicated row registers:
//     - ST_IDLE       : sample req, register first_idx_q -> ST_FIRST_READ
//     - ST_FIRST_READ : NBA row_first_q <= table_ram[first_idx_q]
//                       -> ST_FIRST
//     - ST_FIRST      : decide on row_first_q. Hit/miss -> ST_IDLE.
//                       Collide -> ST_PROBE_READ with probe_idx <- first+1
//     - ST_PROBE_READ : NBA row_probe_q <= table_ram[probe_idx]
//                       -> ST_PROBE
//     - ST_PROBE      : decide on row_probe_q. Hit/miss -> ST_IDLE.
//                       Collide -> ST_PROBE_READ with probe_idx++
//
//   Latency consequence (spec §3.6, §6):
//     - First-probe hit / miss: 3 cycles end-to-end (was 2 post-amendment;
//       was 1 pre-amendment).
//     - Each subsequent probe: 2 cycles (was 1 post-amendment).
//     - Steady-state throughput: 1 op / 3 cycles for the first-probe-hit
//       hot path (was 1 op / 2 cycles).
//
//   Why this is the right shape: registering both stages of the URAM read
//   (index then payload) is exactly the pattern Vivado expects for a
//   2-cycle URAM read. The same NBA-ordering issue that caused the
//   2026-05-11 earlier draft to register row_first_probe_q in ST_IDLE is
//   avoided by reading the payload from a DEDICATED state (ST_FIRST_READ
//   / ST_PROBE_READ) where the bucket index has already settled.
//
//   The req_blocked latch is replaced by a `last_done_q + last_oid_q` guard
//   that ignores held-high reqs *only* when the held oid matches the one
//   we just completed. This preserves the existing tb_order_id_hash
//   "drive req=1 until op_done, then deassert" pattern AND lets the
//   orchestrator drive different oids back-to-back.
//
// Note: lob_core_params_pkg.sv is intentionally NOT `included here — it is
// passed in via VERILOG_SOURCES (the package has no include guard, so
// double-inclusion would trip MODDUP). The package must precede this file
// in the source list because parameter defaults reference it.

/* verilator lint_off VARHIDDEN */
// Module-level parameters intentionally shadow lob_core_params_pkg defaults
// to keep the Vivado/cocotb override names stable (HASH_SLOTS, MAX_PROBE_DEPTH)
// — Phase H wires the orchestrator using these exact names.
module order_id_hash
  import lob_core_params_pkg::*;
#(
    parameter int unsigned HASH_SLOTS      = lob_core_params_pkg::HASH_SLOTS,
    parameter int unsigned MAX_PROBE_DEPTH = lob_core_params_pkg::MAX_PROBE_DEPTH,
    parameter int unsigned SLOT_IDX_W      = 24
) (
    input  logic                  clk,
    input  logic                  rstn,

    input  logic                  insert_req,
    input  logic                  delete_req,
    input  logic                  lookup_req,
    input  logic [63:0]           order_id,
    input  logic [SLOT_IDX_W-1:0] slot_idx_in,

    output logic                  op_done,
    output logic                  op_ok,
    output logic [SLOT_IDX_W-1:0] slot_idx_out,

    output logic [7:0]            hash_probe_max,
    output logic [31:0]           hash_overflow
);
    // Tie off package params not consumed by this module so UNUSEDPARAM
    // doesn't fail the lint (M05 only consumes HASH_SLOTS / MAX_PROBE_DEPTH /
    // HASH_FN here; the rest land in other sub-modules).
    /* verilator lint_off UNUSEDPARAM */
    localparam int unsigned _UNUSED_SYMBOL_FILTER_ID  = SYMBOL_FILTER_ID;
    localparam int unsigned _UNUSED_WINDOW_BASE_TICK  = WINDOW_BASE_TICK;
    localparam int unsigned _UNUSED_WINDOW_SIZE_TICKS = WINDOW_SIZE_TICKS;
    localparam int unsigned _UNUSED_POOL_SLOTS        = POOL_SLOTS;
    // The package-default HASH_SLOTS / MAX_PROBE_DEPTH are overridden by the
    // module-level parameters of the same name; the package symbols are not
    // referenced once shadowed.
    localparam int unsigned _UNUSED_PKG_HASH_SLOTS    = lob_core_params_pkg::HASH_SLOTS;
    localparam int unsigned _UNUSED_PKG_MAX_PROBE     = lob_core_params_pkg::MAX_PROBE_DEPTH;
    /* verilator lint_on UNUSEDPARAM */

    localparam int unsigned BUCKET_W = $clog2(HASH_SLOTS);
    localparam int unsigned PROBE_CW = $clog2(MAX_PROBE_DEPTH + 1);

    // Row layout: {valid, tombstone, _pad (38), order_id (64), slot_idx (24)} = 128 b.
    typedef struct packed {
        logic                       valid;
        logic                       tombstone;
        logic [37:0]                _pad;
        logic [63:0]                order_id;
        logic [SLOT_IDX_W-1:0]      slot_idx;
    } row_t;

    (* ram_style = "ultra" *)
    row_t table_ram [HASH_SLOTS];

    // ------------------------------------------------------------------
    // Hash function — Phase B pinned HASH_XORSHIFT64.
    // ------------------------------------------------------------------
    function automatic logic [63:0] hash64(input logic [63:0] x);
        logic [63:0] h;
        unique case (HASH_FN)
            HASH_XORSHIFT64: begin
                h  = x ^ 64'h9E3779B97F4A7C15;
                h ^= (h << 13);
                h ^= (h >> 7);
                h ^= (h << 17);
            end
            HASH_FIBONACCI: begin
                h = x * 64'h9E3779B97F4A7C15;
            end
            default /* HASH_CRC32 */: begin
                // Phase B pinned XORSHIFT64. CRC32 path intentionally fatals
                // so an un-implemented hash can never silently corrupt
                // results. M07 may revisit hash function alongside HBM.
                h = 64'h0;
                $fatal(1, "order_id_hash: CRC32 hash path not implemented; revisit Phase E");
            end
        endcase
        return h;
    endfunction

    // ------------------------------------------------------------------
    // FSM (post-2026-05-13 amendment) — 5 states:
    //   ST_IDLE        : sample req; register first_idx_q, saved_oid,
    //                    is_*; transition to ST_FIRST_READ.
    //   ST_FIRST_READ  : issue the URAM read for the first probe — NBA
    //                    row_first_q <= table_ram[first_idx_q]. The
    //                    bucket index is already a register at this
    //                    point, so the Vivado URAM cell sees registered
    //                    address -> registered data. State transitions
    //                    to ST_FIRST.
    //   ST_FIRST       : decide hit/miss using row_first_q (the payload
    //                    registered in ST_FIRST_READ). On collide,
    //                    transition to ST_PROBE_READ with probe_idx <-
    //                    first_idx_q+1 and probe_depth <- 1.
    //   ST_PROBE_READ  : issue the URAM read for the current probe —
    //                    NBA row_probe_q <= table_ram[probe_idx].
    //                    Transition to ST_PROBE.
    //   ST_PROBE       : decide using row_probe_q. On collide, advance
    //                    probe_idx and probe_depth, transition back to
    //                    ST_PROBE_READ. Exits to ST_IDLE on hit /
    //                    miss-empty / overflow.
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_FIRST_READ,
        ST_FIRST,
        ST_PROBE_READ,
        ST_PROBE
    } state_e;

    state_e                       state;
    logic [BUCKET_W-1:0]          first_idx_q;       // registered first-probe bucket
    logic [BUCKET_W-1:0]          probe_idx;
    logic [PROBE_CW-1:0]          probe_depth;
    logic [63:0]                  saved_oid;
    logic [SLOT_IDX_W-1:0]        saved_slot;
    logic                         is_insert;
    logic                         is_delete;
    logic                         is_lookup;
    logic [7:0]                   probe_max_q;
    logic [31:0]                  overflow_q;
    logic [SLOT_IDX_W-1:0]        slot_idx_out_q;
    // Held-req guard — replaces the original req_blocked latch. After a
    // completion at edge K, last_done_q=1 and last_oid_q=<that oid> for
    // cycle K+1 only. A held-high req in cycle K+1 with the same oid AND
    // the same op-type as the just-completed op is ignored (TB pattern);
    // a different oid OR a different op-type on the same oid is processed
    // (orchestrator pattern: ADD followed by an immediate Cancel/Exec on
    // the same order_id is common in real ITCH).
    //
    // The op-type check uses the registered is_insert/is_delete/is_lookup
    // flags (set in ST_IDLE for the previous op, persistent through to the
    // cycle after op_done). Pre-fix the guard suppressed the new req
    // without that check, which deadlocked the orchestrator: the new req
    // fired hash_req_fired=1 for one cycle, incremented hash_inflight_q,
    // but the FSM stayed in ST_IDLE — so no op_done ever fired, hash_busy
    // latched high forever, and the lob_core s_tready stuck at 0.
    logic                         last_done_q;
    logic [63:0]                  last_oid_q;
    logic                         ignore_held_req;
    assign ignore_held_req = last_done_q && (order_id == last_oid_q)
                             && (   (is_insert && insert_req)
                                 || (is_delete && delete_req)
                                 || (is_lookup && lookup_req));

    assign hash_probe_max = probe_max_q;
    assign hash_overflow  = overflow_q;
    assign slot_idx_out   = slot_idx_out_q;

    // First-probe bucket = hash mod HASH_SLOTS — combinational on order_id.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] first_h;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [BUCKET_W-1:0] first_idx;
    always_comb first_h   = hash64(order_id);
    always_comb first_idx = first_h[BUCKET_W-1:0];

    // Registered payload reads (post 2026-05-13 amendment). The URAM
    // address comes from already-registered first_idx_q / probe_idx, and
    // the payload is latched into row_first_q / row_probe_q in
    // ST_FIRST_READ / ST_PROBE_READ. Vivado therefore infers UltraRAM
    // with both the address and data ports registered, satisfying the
    // ram_style="ultra" hint. The _pad bits of the struct are stored but
    // never decoded — UNUSEDSIGNAL is fine.
    /* verilator lint_off UNUSEDSIGNAL */
    row_t row_first_q;
    row_t row_probe_q;
    /* verilator lint_on UNUSEDSIGNAL */

    // probe_depth + 1, sized to 8 b for comparison with stat & MAX_PROBE_DEPTH.
    logic [7:0] probe_depth_p1;
    always_comb probe_depth_p1 = 8'(probe_depth) + 8'd1;

    always_ff @(posedge clk) begin
        if (!rstn) begin
            state             <= ST_IDLE;
            op_done           <= 1'b0;
            op_ok             <= 1'b0;
            first_idx_q       <= '0;
            probe_idx         <= '0;
            probe_depth       <= '0;
            saved_oid         <= '0;
            saved_slot        <= '0;
            is_insert         <= 1'b0;
            is_delete         <= 1'b0;
            is_lookup         <= 1'b0;
            probe_max_q       <= '0;
            overflow_q        <= '0;
            slot_idx_out_q    <= '0;
            last_done_q       <= 1'b0;
            last_oid_q        <= '0;
            row_first_q       <= '0;
            row_probe_q       <= '0;
            for (int i = 0; i < HASH_SLOTS; i++) begin
                table_ram[i].valid     <= 1'b0;
                table_ram[i].tombstone <= 1'b0;
                table_ram[i]._pad      <= '0;
                table_ram[i].order_id  <= '0;
                table_ram[i].slot_idx  <= '0;
            end
        end else begin
            op_done     <= 1'b0;
            op_ok       <= 1'b0;
            // last_done_q is a 1-cycle latch — clear unless a completion
            // arms it again this cycle (handled below).
            last_done_q <= 1'b0;

            unique case (state)
                ST_IDLE: begin
                    if (!ignore_held_req && (insert_req || delete_req || lookup_req)) begin
                        first_idx_q <= first_idx;
                        saved_oid   <= order_id;
                        saved_slot  <= slot_idx_in;
                        is_insert   <= insert_req;
                        is_delete   <= delete_req;
                        is_lookup   <= lookup_req;
                        state       <= ST_FIRST_READ;
                    end
                end

                ST_FIRST_READ: begin
                    // Register the URAM payload using the already-registered
                    // first_idx_q. The NBA-ordering bug that the 2026-05-11
                    // amendment file note flagged is avoided because
                    // first_idx_q was registered one cycle ago (in ST_IDLE),
                    // so by ST_FIRST_READ it already holds the post-NBA
                    // value. table_ram[first_idx_q] is therefore the correct
                    // bucket.
                    row_first_q <= table_ram[first_idx_q];
                    state       <= ST_FIRST;
                end

                ST_FIRST: begin
                    // Saturating max-probe-depth stat — first probe is depth 1.
                    if (8'd1 > probe_max_q) probe_max_q <= 8'd1;

                    if (is_lookup) begin
                        if (row_first_q.valid && row_first_q.order_id == saved_oid) begin
                            slot_idx_out_q <= row_first_q.slot_idx;
                            op_done        <= 1'b1;
                            op_ok          <= 1'b1;
                            last_done_q    <= 1'b1;
                            last_oid_q     <= saved_oid;
                            state          <= ST_IDLE;
                        end else if (!row_first_q.valid && !row_first_q.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= PROBE_CW'(1);
                            probe_idx   <= first_idx_q + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end else if (is_insert) begin
                        if (!row_first_q.valid || row_first_q.tombstone) begin
                            table_ram[first_idx_q].valid     <= 1'b1;
                            table_ram[first_idx_q].tombstone <= 1'b0;
                            table_ram[first_idx_q].order_id  <= saved_oid;
                            table_ram[first_idx_q].slot_idx  <= saved_slot;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= PROBE_CW'(1);
                            probe_idx   <= first_idx_q + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end else /* is_delete */ begin
                        if (row_first_q.valid && row_first_q.order_id == saved_oid) begin
                            table_ram[first_idx_q].valid     <= 1'b0;
                            table_ram[first_idx_q].tombstone <= 1'b1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (!row_first_q.valid && !row_first_q.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= PROBE_CW'(1);
                            probe_idx   <= first_idx_q + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end
                end

                ST_PROBE_READ: begin
                    // Same registered-payload pattern as ST_FIRST_READ:
                    // probe_idx was registered in the previous cycle (either
                    // from ST_FIRST's collide branch or from ST_PROBE's
                    // collide branch), so reading table_ram[probe_idx] here
                    // gives the correct probe bucket.
                    row_probe_q <= table_ram[probe_idx];
                    state       <= ST_PROBE;
                end

                ST_PROBE: begin
                    // Update saturating max-probe-depth stat (probe_depth_p1
                    // is the depth being decided this cycle for ST_PROBE).
                    if (probe_depth_p1 > probe_max_q) begin
                        probe_max_q <= probe_depth_p1;
                    end

                    if (is_lookup) begin
                        if (row_probe_q.valid && row_probe_q.order_id == saved_oid) begin
                            slot_idx_out_q <= row_probe_q.slot_idx;
                            op_done        <= 1'b1;
                            op_ok          <= 1'b1;
                            last_done_q    <= 1'b1;
                            last_oid_q     <= saved_oid;
                            state          <= ST_IDLE;
                        end else if (!row_probe_q.valid && !row_probe_q.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (probe_depth_p1 >= 8'(MAX_PROBE_DEPTH)) begin
                            overflow_q  <= overflow_q + 32'd1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= probe_depth + PROBE_CW'(1);
                            probe_idx   <= probe_idx + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end else if (is_insert) begin
                        if (!row_probe_q.valid || row_probe_q.tombstone) begin
                            table_ram[probe_idx].valid     <= 1'b1;
                            table_ram[probe_idx].tombstone <= 1'b0;
                            table_ram[probe_idx].order_id  <= saved_oid;
                            table_ram[probe_idx].slot_idx  <= saved_slot;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (probe_depth_p1 >= 8'(MAX_PROBE_DEPTH)) begin
                            overflow_q  <= overflow_q + 32'd1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= probe_depth + PROBE_CW'(1);
                            probe_idx   <= probe_idx + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end else if (is_delete) begin
                        if (row_probe_q.valid && row_probe_q.order_id == saved_oid) begin
                            table_ram[probe_idx].valid     <= 1'b0;
                            table_ram[probe_idx].tombstone <= 1'b1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (!row_probe_q.valid && !row_probe_q.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (probe_depth_p1 >= 8'(MAX_PROBE_DEPTH)) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= probe_depth + PROBE_CW'(1);
                            probe_idx   <= probe_idx + BUCKET_W'(1);
                            state       <= ST_PROBE_READ;
                        end
                    end else begin
                        // Defensive fallback — all op-class flags low.
                        op_done     <= 1'b1;
                        op_ok       <= 1'b0;
                        last_done_q <= 1'b1;
                        last_oid_q  <= saved_oid;
                        state       <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule : order_id_hash
/* verilator lint_on VARHIDDEN */
