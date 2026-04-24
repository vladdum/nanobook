`timescale 1ns/1ps
// Lint-only stub for the Xilinx XDMA IP.
// NOT included in synthesis; lets Verilator resolve xdma_pcie module.
// Port list matches Vivado 2025.2 XDMA 4.2 generated xdma_pcie.veo stub.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
module xdma_pcie (
  // PCIe system
  input  wire         sys_clk,
  input  wire         sys_clk_gt,
  input  wire         sys_rst_n,
  // PCIe GT lanes
  input  wire  [3:0]  pci_exp_rxp,
  input  wire  [3:0]  pci_exp_rxn,
  output wire  [3:0]  pci_exp_txp,
  output wire  [3:0]  pci_exp_txn,
  // User clock / reset
  output logic        axi_aclk,
  output logic        axi_aresetn,
  // PCIe link status
  output logic        user_lnk_up,
  // User interrupt
  input  wire  [0:0]  usr_irq_req,
  output logic [0:0]  usr_irq_ack,
  output logic        msi_enable,
  output logic [2:0]  msi_vector_width,
  // AXI-Lite master (BAR0)
  output logic [31:0] m_axil_awaddr,
  output logic [2:0]  m_axil_awprot,
  output logic        m_axil_awvalid,
  input  logic        m_axil_awready,
  output logic [31:0] m_axil_wdata,
  output logic [3:0]  m_axil_wstrb,
  output logic        m_axil_wvalid,
  input  logic        m_axil_wready,
  input  logic [1:0]  m_axil_bresp,
  input  logic        m_axil_bvalid,
  output logic        m_axil_bready,
  output logic [31:0] m_axil_araddr,
  output logic [2:0]  m_axil_arprot,
  output logic        m_axil_arvalid,
  input  logic        m_axil_arready,
  input  logic [31:0] m_axil_rdata,
  input  logic [1:0]  m_axil_rresp,
  input  logic        m_axil_rvalid,
  output logic        m_axil_rready,
  // AXI4 DMA master (m_axi_*)
  input  wire         m_axi_awready,
  input  wire         m_axi_wready,
  input  wire  [3:0]  m_axi_bid,
  input  wire  [1:0]  m_axi_bresp,
  input  wire         m_axi_bvalid,
  input  wire         m_axi_arready,
  input  wire  [3:0]  m_axi_rid,
  input  wire [255:0] m_axi_rdata,
  input  wire  [1:0]  m_axi_rresp,
  input  wire         m_axi_rlast,
  input  wire         m_axi_rvalid,
  output logic [3:0]  m_axi_awid,
  output logic [63:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic [2:0]  m_axi_awprot,
  output logic        m_axi_awvalid,
  output logic        m_axi_awlock,
  output logic [3:0]  m_axi_awcache,
  output logic [255:0] m_axi_wdata,
  output logic [31:0] m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  output logic        m_axi_bready,
  output logic [3:0]  m_axi_arid,
  output logic [63:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic [2:0]  m_axi_arprot,
  output logic        m_axi_arvalid,
  output logic        m_axi_arlock,
  output logic [3:0]  m_axi_arcache,
  output logic        m_axi_rready,
  // PCIe config management
  input  wire [18:0]  cfg_mgmt_addr,
  input  wire         cfg_mgmt_write,
  input  wire [31:0]  cfg_mgmt_write_data,
  input  wire  [3:0]  cfg_mgmt_byte_enable,
  input  wire         cfg_mgmt_read,
  output logic [31:0] cfg_mgmt_read_data,
  output logic        cfg_mgmt_read_write_done
);
  assign pci_exp_txp             = '0;
  assign pci_exp_txn             = '0;
  assign axi_aclk                = 1'b0;
  assign axi_aresetn             = 1'b0;
  assign m_axil_awaddr           = '0;
  assign m_axil_awprot           = '0;
  assign m_axil_awvalid          = 1'b0;
  assign m_axil_wdata            = '0;
  assign m_axil_wstrb            = '0;
  assign m_axil_wvalid           = 1'b0;
  assign m_axil_bready           = 1'b0;
  assign m_axil_araddr           = '0;
  assign m_axil_arprot           = '0;
  assign m_axil_arvalid          = 1'b0;
  // m_axil_rresp is an input (slave drives it); not driven by this stub
  assign m_axil_rready           = 1'b0;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
