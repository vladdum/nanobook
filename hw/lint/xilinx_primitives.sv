// Lint-only stubs for Xilinx UltraScale+ primitives used in RTL.
// NOT included in synthesis.
`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDPARAM */

module IBUFDS (
  input  wire I,
  input  wire IB,
  output wire O
);
  assign O = I;
endmodule

module IBUFDS_GTE4 #(
  parameter [1:0] REFCLK_HROW_CK_SEL = 2'b00
)(
  input  wire I,
  input  wire IB,
  input  wire CEB,
  output wire O,
  output wire ODIV2
);
  assign O     = I;
  assign ODIV2 = I;
endmodule

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
