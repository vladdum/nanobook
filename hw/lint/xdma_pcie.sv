`timescale 1ns/1ps
// Lint-only stub for the Xilinx XDMA IP.
// NOT included in synthesis; lets Verilator resolve xdma_pcie module.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
module xdma_pcie (
  input  wire  [15:0] pci_exp_rxp,
  input  wire  [15:0] pci_exp_rxn,
  output wire  [15:0] pci_exp_txp,
  output wire  [15:0] pci_exp_txn,
  input  wire         sys_clk_p,
  input  wire         sys_clk_n,
  input  wire         sys_rst_n,
  output logic        axi_aclk,
  output logic        axi_aresetn,
  output logic [31:0] m_axil_awaddr,
  output logic        m_axil_awvalid,
  input  logic        m_axil_awready,
  output logic [31:0] m_axil_wdata,
  output logic        m_axil_wvalid,
  input  logic        m_axil_wready,
  input  logic [1:0]  m_axil_bresp,
  input  logic        m_axil_bvalid,
  output logic        m_axil_bready,
  output logic [31:0] m_axil_araddr,
  output logic        m_axil_arvalid,
  input  logic        m_axil_arready,
  input  logic [31:0] m_axil_rdata,
  output logic [1:0]  m_axil_rresp,
  input  logic        m_axil_rvalid,
  output logic        m_axil_rready
);
  assign pci_exp_txp    = '0;
  assign pci_exp_txn    = '0;
  assign axi_aclk       = 1'b0;
  assign axi_aresetn    = 1'b0;
  assign m_axil_awaddr  = '0;
  assign m_axil_awvalid = 1'b0;
  assign m_axil_wdata   = '0;
  assign m_axil_wvalid  = 1'b0;
  assign m_axil_bready  = 1'b0;
  assign m_axil_araddr  = '0;
  assign m_axil_arvalid = 1'b0;
  assign m_axil_rresp   = 2'b00;
  assign m_axil_rready  = 1'b0;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
