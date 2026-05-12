// SPDX-License-Identifier: Apache-2.0
// per_sym_state — distRAM regfile holding per-symbol sliding-window state.
//
// Spec: docs/design.md §3.5 (per-symbol epoch + origin + midprice +
// rebase_count). M06's sliding-window rebase logic uses this to detect
// out-of-window ADDs and stamp ins_epoch on pool records.
// Plan: docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md
//       Task F.1.
//
// Layout per symbol:
//   epoch        [EPOCH_W-1:0]   bumps on every rebase. ins_epoch on pool
//                                records is compared against this for the
//                                stale-check at d3.
//   origin       [31:0]          low tick of the current window (= midprice
//                                - WINDOW_HALF_TICKS, clamped at 0). All
//                                price→bitmap-idx math derives from here.
//   midprice     [31:0]          tracked EMA of recent trade prices. The
//                                lob_core EMA path writes this every
//                                committed ADD via write_kind=0.
//   rebase_count [15:0]          monotonic count of rebases this symbol
//                                has seen (BAR0 stat).
//
// Read port is combinational (distRAM); write port is synchronous.
// Initialisation comes from the lob_core_sym_pkg::INITIAL_MIDPRICE
// parameter — sized N_SYMBOLS so unused entries default to 0.

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off VARHIDDEN */
module per_sym_state #(
    parameter int unsigned N_SYMBOLS         = lob_core_params_pkg::N_SYMBOLS,
    parameter int unsigned SYM_IDX_W         = lob_core_params_pkg::SYM_IDX_W,
    parameter int unsigned EPOCH_W           = lob_core_params_pkg::EPOCH_W,
    parameter int unsigned WINDOW_HALF_TICKS = lob_core_params_pkg::WINDOW_HALF_TICKS,
    // INITIAL_MIDPRICE table is sized to N_SYMBOLS_USED (= 100 for the
    // 2026-04-25 selection) rather than the padded N_SYMBOLS; entries
    // beyond N_SYMBOLS_USED default to 0 (origin saturates at 0).
    parameter int unsigned N_SYMBOLS_USED                       = 100,
    parameter logic [31:0] INITIAL_MIDPRICE [N_SYMBOLS_USED]    = '{default: 32'd0}
) (
/* verilator lint_on VARHIDDEN */
/* verilator lint_on UNUSEDPARAM */
    input  logic                       clk,
    input  logic                       rstn,

    // Read port 1 (combinational) — driven by lob_core's ADD path.
    input  logic [SYM_IDX_W-1:0]       read_sym,
    output logic [EPOCH_W-1:0]         read_epoch,
    output logic [31:0]                read_origin,
    output logic [31:0]                read_midprice,
    output logic [15:0]                read_rebase_count,

    // Read port 2 (combinational) — driven by lob_core's DEL d3 stale check.
    // distRAM supports multiple read ports cheaply; the duplicated read
    // address path lets ADD and DEL paths read different syms concurrently.
    // F.2 §2: port 2 also surfaces the origin so the DEL ladder addr_of
    // uses the correct per-sym base.
    input  logic [SYM_IDX_W-1:0]       read2_sym,
    output logic [EPOCH_W-1:0]         read2_epoch,
    output logic [31:0]                read2_origin,

    // Write port (synchronous)
    input  logic                       write_en,
    input  logic [SYM_IDX_W-1:0]       write_sym,
    input  logic                       write_kind,    // 0=EMA midprice, 1=rebase
    input  logic [31:0]                write_origin,
    input  logic [31:0]                write_midprice
);
    // Sibling-package parameter touch — keeps the standalone lint clean
    // when imported via lob_core's package list.
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
    localparam int unsigned _PKG_CLZ_LATENCY        =
        lob_core_params_pkg::CLZ_LATENCY;
    /* verilator lint_on UNUSEDPARAM */

    (* ram_style = "distributed" *)
    logic [EPOCH_W-1:0]  epoch_reg     [N_SYMBOLS];
    (* ram_style = "distributed" *)
    logic [31:0]         origin_reg    [N_SYMBOLS];
    (* ram_style = "distributed" *)
    logic [31:0]         midprice_reg  [N_SYMBOLS];
    (* ram_style = "distributed" *)
    logic [15:0]         rb_count_reg  [N_SYMBOLS];

    // Initial midprice values larger than the half-window decay safely to a
    // valid origin; smaller initial values (or zeros for padding entries
    // beyond N_SYMBOLS_USED) saturate at 0 to keep the origin ≥ 0.
    function automatic logic [31:0] initial_origin(input logic [31:0] mid);
        return (mid >= 32'(WINDOW_HALF_TICKS))
                ? mid - 32'(WINDOW_HALF_TICKS)
                : 32'd0;
    endfunction

    always_ff @(posedge clk) begin
        if (!rstn) begin
            for (int i = 0; i < N_SYMBOLS; i++) begin
                epoch_reg[i]    <= '0;
                rb_count_reg[i] <= '0;
                if (i < N_SYMBOLS_USED) begin
                    origin_reg[i]   <= initial_origin(INITIAL_MIDPRICE[i]);
                    midprice_reg[i] <= INITIAL_MIDPRICE[i];
                end else begin
                    origin_reg[i]   <= 32'd0;
                    midprice_reg[i] <= 32'd0;
                end
            end
        end else if (write_en) begin
            midprice_reg[write_sym] <= write_midprice;
            if (write_kind) begin   // rebase
                epoch_reg[write_sym]    <= epoch_reg[write_sym] + 1'b1;
                origin_reg[write_sym]   <= write_origin;
                rb_count_reg[write_sym] <= rb_count_reg[write_sym] + 1'b1;
            end
        end
    end

    // Combinational reads (distRAM)
    assign read_epoch        = epoch_reg[read_sym];
    assign read_origin       = origin_reg[read_sym];
    assign read_midprice     = midprice_reg[read_sym];
    assign read_rebase_count = rb_count_reg[read_sym];
    assign read2_epoch       = epoch_reg[read2_sym];
    assign read2_origin      = origin_reg[read2_sym];

endmodule : per_sym_state
