`timescale 1ns/1ps
// Lint-only stub for the Xilinx HBM IP.
// NOT included in synthesis; lets Verilator resolve the hbm module.
// Actual port names must be verified against PG276 and the generated .veo.
// Only the ports required by hbm_wrapper are listed here.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
module hbm (
  // Reference clocks
  input  wire         HBM_REF_CLK_0,
  input  wire         HBM_REF_CLK_1,
  // AXI port 0 (used by hbm_traffic_gen)
  input  wire         AXI_00_ACLK,
  input  wire         AXI_00_ARESET_N,
  input  wire [7:0]   AXI_00_AWID,
  input  wire [32:0]  AXI_00_AWADDR,
  input  wire [7:0]   AXI_00_AWLEN,
  input  wire [2:0]   AXI_00_AWSIZE,
  input  wire [1:0]   AXI_00_AWBURST,
  input  wire         AXI_00_AWVALID,
  output logic        AXI_00_AWREADY,
  input  wire [255:0] AXI_00_WDATA,
  input  wire [31:0]  AXI_00_WSTRB,
  input  wire         AXI_00_WLAST,
  input  wire         AXI_00_WVALID,
  output logic        AXI_00_WREADY,
  output logic [7:0]  AXI_00_BID,
  output logic [1:0]  AXI_00_BRESP,
  output logic        AXI_00_BVALID,
  input  wire         AXI_00_BREADY,
  input  wire [7:0]   AXI_00_ARID,
  input  wire [32:0]  AXI_00_ARADDR,
  input  wire [7:0]   AXI_00_ARLEN,
  input  wire [2:0]   AXI_00_ARSIZE,
  input  wire [1:0]   AXI_00_ARBURST,
  input  wire         AXI_00_ARVALID,
  output logic        AXI_00_ARREADY,
  output logic [7:0]  AXI_00_RID,
  output logic [255:0] AXI_00_RDATA,
  output logic [1:0]  AXI_00_RRESP,
  output logic        AXI_00_RLAST,
  output logic        AXI_00_RVALID,
  input  wire         AXI_00_RREADY,
  // Status
  output logic        apb_complete_0,
  output logic        apb_complete_1
);
  assign AXI_00_AWREADY  = 1'b1;
  assign AXI_00_WREADY   = 1'b1;
  assign AXI_00_BID      = '0;
  assign AXI_00_BRESP    = 2'b00;
  assign AXI_00_BVALID   = 1'b0;
  assign AXI_00_ARREADY  = 1'b1;
  assign AXI_00_RID      = '0;
  assign AXI_00_RDATA    = '0;
  assign AXI_00_RRESP    = 2'b00;
  assign AXI_00_RLAST    = 1'b0;
  assign AXI_00_RVALID   = 1'b0;
  assign apb_complete_0  = 1'b1;
  assign apb_complete_1  = 1'b1;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
