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
//   into first_idx_q; ST_FIRST decides hit/miss using row_first
//   (combinational read of table_ram[first_idx_q]); ST_PROBE continues
//   multi-probe traversal with the same combinational read pattern
//   (row_at_probe tracks table_ram[probe_idx]). The timing fix is that
//   the first-probe BUCKET INDEX is now registered — the URAM read
//   itself stays combinational on a register, giving the Fmax-friendly
//   stage register -> URAM read -> decision logic -> write-CE register
//   (identical pattern to ST_PROBE). Each op takes 2 cycles end-to-end
//   (was 1). Subsequent probes pipeline at 1 cycle each. Steady-state
//   throughput = 1 op / 2 cycles (was 1/cycle).
//
//   Note: an earlier draft of this amendment registered the URAM READ
//   OUTPUT (row_first_probe_q <= table_ram[first_idx_q]) instead of
//   relying on the registered bucket index. That was a bug: NBA
//   ordering meant row_first_probe_q latched table_ram[OLD first_idx_q]
//   on the same edge first_idx_q took its new value, so ST_FIRST
//   decided on the WRONG bucket the next cycle. Fixed by reverting to a
//   combinational row_first read on the (already registered) first_idx_q.
//
//   Spec authority: docs/superpowers/specs/2026-05-09-nanobook-m05-book-
//   core-uram-design.md §3.6 (2026-05-11 amendment).
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
    // FSM (post-2026-05-11 amendment) — 3 states:
    //   ST_IDLE  : sample req; register first_idx_q, saved_oid, is_*;
    //              transition to ST_FIRST. Do NOT assert op_done.
    //   ST_FIRST : decide hit/miss using row_first (combinational
    //              read of table_ram[first_idx_q] — the bucket index is
    //              already registered, so the arc here is register ->
    //              URAM read -> decision logic -> write-CE register, a
    //              clean Fmax stage identical to ST_PROBE). On collide,
    //              transition to ST_PROBE with probe_idx <- first_idx_q+1
    //              and probe_depth <- 1.
    //   ST_PROBE : continue probing using row_at_probe (combinational
    //              read of table_ram[probe_idx]); on collide, advance
    //              probe_idx and probe_depth. Exits to ST_IDLE on
    //              hit / miss-empty / overflow.
    //              Note: row_at_probe is combinational on purpose. The
    //              amendment's timing fix targets the FIRST probe path
    //              (where the bucket index was a long hash chain from
    //              order_id). PROBE iterations already start from the
    //              probe_idx register, so the timing arc here is
    //              register -> URAM read -> decide -> write-CE register
    //              -- a clean Fmax stage. An extra register on PROBE
    //              would force a wait cycle between iterations and
    //              defeat the spec's "subsequent probes pipeline at 1
    //              cycle each" guarantee.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_FIRST,
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
    // cycle K+1 only. A held-high req in cycle K+1 with the same oid is
    // ignored (TB pattern); a different oid in cycle K+1 is processed
    // (orchestrator pattern).
    logic                         last_done_q;
    logic [63:0]                  last_oid_q;
    logic                         ignore_held_req;
    assign ignore_held_req = last_done_q && (order_id == last_oid_q);

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

    // ST_FIRST: combinational read of table_ram[first_idx_q]. The
    // first_idx_q register is the start of this 1-cycle path, so the
    // critical path here is register -> URAM read -> decision logic ->
    // write-CE register, which is a clean Fmax-friendly stage. The
    // amendment's timing fix targets the FIRST path by registering the
    // BUCKET INDEX (the long combinational hash from order_id was the
    // problem, not the row output).
    /* verilator lint_off UNUSEDSIGNAL */
    row_t row_first;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb row_first = table_ram[first_idx_q];

    // ST_PROBE: combinational read of table_ram[probe_idx]. Same pattern
    // as row_first above — probe_idx is already a register, so the arc
    // is register -> URAM read -> decide -> write-CE register.
    /* verilator lint_off UNUSEDSIGNAL */
    row_t row_at_probe;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb row_at_probe = table_ram[probe_idx];

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
                        state       <= ST_FIRST;
                    end
                end

                ST_FIRST: begin
                    // Saturating max-probe-depth stat — first probe is depth 1.
                    if (8'd1 > probe_max_q) probe_max_q <= 8'd1;

                    if (is_lookup) begin
                        if (row_first.valid && row_first.order_id == saved_oid) begin
                            slot_idx_out_q <= row_first.slot_idx;
                            op_done        <= 1'b1;
                            op_ok          <= 1'b1;
                            last_done_q    <= 1'b1;
                            last_oid_q     <= saved_oid;
                            state          <= ST_IDLE;
                        end else if (!row_first.valid && !row_first.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= PROBE_CW'(1);
                            probe_idx   <= first_idx_q + BUCKET_W'(1);
                            state       <= ST_PROBE;
                        end
                    end else if (is_insert) begin
                        if (!row_first.valid || row_first.tombstone) begin
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
                            state       <= ST_PROBE;
                        end
                    end else /* is_delete */ begin
                        if (row_first.valid && row_first.order_id == saved_oid) begin
                            table_ram[first_idx_q].valid     <= 1'b0;
                            table_ram[first_idx_q].tombstone <= 1'b1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (!row_first.valid && !row_first.tombstone) begin
                            op_done     <= 1'b1;
                            op_ok       <= 1'b0;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else begin
                            probe_depth <= PROBE_CW'(1);
                            probe_idx   <= first_idx_q + BUCKET_W'(1);
                            state       <= ST_PROBE;
                        end
                    end
                end

                ST_PROBE: begin
                    // Update saturating max-probe-depth stat (probe_depth_p1
                    // is the depth being decided this cycle for ST_PROBE).
                    if (probe_depth_p1 > probe_max_q) begin
                        probe_max_q <= probe_depth_p1;
                    end

                    if (is_lookup) begin
                        if (row_at_probe.valid && row_at_probe.order_id == saved_oid) begin
                            slot_idx_out_q <= row_at_probe.slot_idx;
                            op_done        <= 1'b1;
                            op_ok          <= 1'b1;
                            last_done_q    <= 1'b1;
                            last_oid_q     <= saved_oid;
                            state          <= ST_IDLE;
                        end else if (!row_at_probe.valid && !row_at_probe.tombstone) begin
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
                        end
                    end else if (is_insert) begin
                        if (!row_at_probe.valid || row_at_probe.tombstone) begin
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
                        end
                    end else if (is_delete) begin
                        if (row_at_probe.valid && row_at_probe.order_id == saved_oid) begin
                            table_ram[probe_idx].valid     <= 1'b0;
                            table_ram[probe_idx].tombstone <= 1'b1;
                            op_done     <= 1'b1;
                            op_ok       <= 1'b1;
                            last_done_q <= 1'b1;
                            last_oid_q  <= saved_oid;
                            state       <= ST_IDLE;
                        end else if (!row_at_probe.valid && !row_at_probe.tombstone) begin
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
