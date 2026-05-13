// SPDX-License-Identifier: Apache-2.0
// uram_sdp — Simple-Dual-Port UltraRAM wrapper.
//
// One sync write port, one sync read port (read latency = 1 cycle).
// Inferred as URAM via `(* ram_style = "ultra" *)`. The single in-module
// pattern (flat bit-vector + initial-init + one always_ff with sync read/
// write) is the only one Vivado has been observed to fold into a URAM
// cell cleanly in this project's prior synth runs (see order_pool.sv —
// the only inline array that inferred URAM on the 2026-05-13 OOC synth).
//
// The 2026-05-13 OOC synth attempt on lob_core showed Synth 8-7186 firing
// once per (level, field) pair when `levels` was declared as a packed
// struct array — Vivado decomposed the struct, each per-field array was
// too small for URAM, and `ram_style="ultra"` was silently ignored. The
// only safe path is to keep storage as a single flat bit-vector and pack/
// unpack at the wrapper boundary.
//
// Initialization: `initial begin ... mem[i] = '0 ... end` sets all rows
// to zero at config time. Vivado URAMs do not have a reset port, but the
// 2025.2 synth tool accepts an `initial` block as the URAM `INIT_*`
// source, so reads of never-written addresses return zero deterministically
// (matters for price_ladder, where an empty level must read count=0).
// For Verilator the same `initial` block fixes simulation determinism
// without depending on +verilator+rand+reset.
//
// Read-before-write semantics: if `we` and `re` are both asserted at the
// same cycle with `waddr == raddr`, `rdata` returns the OLD value (the
// pre-write content). This is the "read-first" / "read-before-write"
// mode — matches the natural URAM behaviour and is what the callers
// expect (they handle write→read hazards via an external 1-deep bypass
// register).

module uram_sdp #(
    parameter int unsigned WIDTH = 72,
    parameter int unsigned DEPTH = 4096
) (
    input  logic                         clk,

    input  logic                         we,
    input  logic [$clog2(DEPTH)-1:0]     waddr,
    input  logic [WIDTH-1:0]             wdata,

    input  logic                         re,
    input  logic [$clog2(DEPTH)-1:0]     raddr,
    output logic [WIDTH-1:0]             rdata
);
    (* ram_style = "ultra" *)
    logic [WIDTH-1:0] mem [DEPTH];

    // Config-time init — gives Vivado a URAM INIT source AND keeps the
    // simulator (Verilator / Vivado xsim) deterministic on reads of
    // never-written addresses.
    initial begin
        for (int i = 0; i < DEPTH; i++) begin
            mem[i] = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata       <= mem[raddr];
    end

endmodule : uram_sdp
