// SPDX-License-Identifier: Apache-2.0
// order_pool — URAM-backed slot allocator + record store.
//
// Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
//   §3.1 (role in datapath), §3.2 step 1-2, §3.3 step 2-3, §5.1 (sizing).
//
// - Free-list: stack of available slot indices, depth = POOL_SLOTS, init = identity.
// - Record store: dual-port URAM, 256-bit rows, depth = POOL_SLOTS.
//   Two read ports (read0, read1), one write port. URAM macro choice
//   left to synth — synth_attribute ram_style = "ultra".
// - Cycle latency: alloc / free / write / read each = 1 cycle (URAM hit).
//
// Standalone parameterised: this module does NOT import
// lob_core_params_pkg — POOL_SLOTS / RECORD_W are passed as parameters
// so that per-target unit Makefiles need not pull in the package (avoids
// UNUSEDPARAM warnings on the package symbols not consumed here).

module order_pool #(
    parameter int unsigned POOL_SLOTS = 8192,
    parameter int unsigned RECORD_W   = 256
) (
    input  logic                            clk,
    input  logic                            rstn,

    // Allocator interface
    input  logic                            alloc_req,
    output logic                            alloc_valid,
    output logic [$clog2(POOL_SLOTS)-1:0]   alloc_slot,

    input  logic                            free_req,
    input  logic [$clog2(POOL_SLOTS)-1:0]   free_slot,

    // Write port (single)
    input  logic                            write_req,
    input  logic [$clog2(POOL_SLOTS)-1:0]   write_slot,
    input  logic [RECORD_W-1:0]             write_record,

    // Read port 0
    input  logic                            read0_req,
    input  logic [$clog2(POOL_SLOTS)-1:0]   read0_slot,
    output logic [RECORD_W-1:0]             read0_record,

    // Read port 1
    input  logic                            read1_req,
    input  logic [$clog2(POOL_SLOTS)-1:0]   read1_slot,
    output logic [RECORD_W-1:0]             read1_record,

    // Stat
    output logic [31:0]                     pool_exhausted
);
    localparam int unsigned IDX_W = $clog2(POOL_SLOTS);

    // ------------------------------------------------------------------
    // Free-list — implemented as a stack (LIFO). Initialised on reset to
    // the identity (slot 0..POOL_SLOTS-1 free, top-of-stack = POOL_SLOTS).
    // free_top_q is one bit wider than IDX_W so it can represent both
    // "empty" (0) and "full" (POOL_SLOTS).
    // ------------------------------------------------------------------
    logic [IDX_W-1:0] free_stack [POOL_SLOTS];
    logic [IDX_W:0]   free_top_q;
    logic [31:0]      pool_exhausted_q;

    assign pool_exhausted = pool_exhausted_q;

    // Combinational helpers — kept narrow on purpose so array indexing
    // is width-clean to Verilator -Wall.
    logic [IDX_W-1:0] alloc_idx;   // = free_top_q - 1, low bits
    logic [IDX_W-1:0] free_idx;    // = free_top_q,     low bits
    assign alloc_idx = free_top_q[IDX_W-1:0] - { {(IDX_W-1){1'b0}}, 1'b1 };
    assign free_idx  = free_top_q[IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (!rstn) begin
            // Initialise stack with all slot indices.
            for (int i = 0; i < POOL_SLOTS; i++) begin
                free_stack[i] <= IDX_W'(i);
            end
            free_top_q       <= (IDX_W+1)'(POOL_SLOTS);
            alloc_valid      <= 1'b0;
            alloc_slot       <= '0;
            pool_exhausted_q <= '0;
        end else begin
            alloc_valid <= 1'b0;
            if (alloc_req) begin
                if (free_top_q == '0) begin
                    pool_exhausted_q <= pool_exhausted_q + 32'd1;
                end else begin
                    alloc_valid <= 1'b1;
                    alloc_slot  <= free_stack[alloc_idx];
                    free_top_q  <= free_top_q - { {IDX_W{1'b0}}, 1'b1 };
                end
            end
            if (free_req) begin
                free_stack[free_idx] <= free_slot;
                free_top_q           <= free_top_q + { {IDX_W{1'b0}}, 1'b1 };
            end
        end
    end

    // ------------------------------------------------------------------
    // Record store — true dual-port URAM, write-through.
    // The synth attribute hints Vivado toward URAM; if width-packing
    // doesn't naturally land in URAM, Phase K will re-tune.
    // ------------------------------------------------------------------
    (* ram_style = "ultra" *)
    logic [RECORD_W-1:0] records [POOL_SLOTS];

    always_ff @(posedge clk) begin
        if (write_req) records[write_slot] <= write_record;
        if (read0_req) read0_record        <= records[read0_slot];
        if (read1_req) read1_record        <= records[read1_slot];
    end

endmodule : order_pool
