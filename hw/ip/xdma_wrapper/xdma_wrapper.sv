// Thin wrapper around the Xilinx XDMA IP and the Nanobook BAR0 register file.
//
// NOTE: xdma_pcie port names below are representative based on PG195 (v4.1).
//       Verify against the generated IP stub (.veo) before the first build.
//       Run `generate_target simulation` in xdma_pcie.tcl to produce the stub.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module xdma_wrapper (
  // PCIe hard-block pins
  input  wire         pcie_refclk_p,
  input  wire         pcie_refclk_n,
  input  wire         pcie_rstn,
  input  wire  [15:0] pcie_rx_p,
  input  wire  [15:0] pcie_rx_n,
  output wire  [15:0] pcie_tx_p,
  output wire  [15:0] pcie_tx_n,

  // User-domain clock and reset (driven by XDMA IP, 250 MHz)
  output logic        user_clk,
  output logic        user_rstn,

  // Status inputs (tied low until HBM/10G wrappers exist)
  input  logic        hbm_ready_i,
  input  logic        eth10g_ready_i,
  input  logic        hbm_done_i,
  input  logic        hbm_any_error_i,

  // Build-time SHA (from build_sha.vh defines, passed in by shell top)
  input  logic [31:0] git_sha_lo_i,
  input  logic [31:0] git_sha_hi_i,

  // Control outputs (to shell logic)
  output logic [2:0]  control_o,
  output logic [3:0]  gpio_led_o,
  // HBM smoke-test trigger (CONTROL[4])
  output logic        hbm_smoke_go_o
);

  // -------------------------------------------------------------------------
  // AXI-Lite master wires from XDMA to xdma_regs
  // Port names match PG195 §3 "AXI4-Lite Master Interface" column.
  // -------------------------------------------------------------------------
  logic [31:0] m_axil_awaddr;
  logic        m_axil_awvalid;
  logic        m_axil_awready;
  logic [31:0] m_axil_wdata;
  logic        m_axil_wvalid;
  logic        m_axil_wready;
  logic        m_axil_bvalid;
  logic        m_axil_bready;
  logic [31:0] m_axil_araddr;
  logic        m_axil_arvalid;
  logic        m_axil_arready;
  logic [31:0] m_axil_rdata;
  logic [1:0]  m_axil_rresp;  // RRESP from XDMA; always OKAY, unused by regs
  logic        m_axil_rvalid;
  logic        m_axil_rready;

  // -------------------------------------------------------------------------
  // Xilinx XDMA IP instantiation
  // -------------------------------------------------------------------------
  xdma_pcie u_xdma (
    // PCIe GT
    .pci_exp_rxp          (pcie_rx_p),
    .pci_exp_rxn          (pcie_rx_n),
    .pci_exp_txp          (pcie_tx_p),
    .pci_exp_txn          (pcie_tx_n),
    // Reference clock (differential; IBUFDS inside IP)
    .sys_clk_p            (pcie_refclk_p),
    .sys_clk_n            (pcie_refclk_n),
    // Active-low reset from PCIe connector
    .sys_rst_n            (pcie_rstn),
    // User clock / reset outputs
    .axi_aclk             (user_clk),
    .axi_aresetn          (user_rstn),
    // AXI-Lite master (BAR0 → xdma_regs)
    .m_axil_awaddr        (m_axil_awaddr),
    .m_axil_awvalid       (m_axil_awvalid),
    .m_axil_awready       (m_axil_awready),
    .m_axil_wdata         (m_axil_wdata),
    .m_axil_wvalid        (m_axil_wvalid),
    .m_axil_wready        (m_axil_wready),
    .m_axil_bresp         (2'b00),           // tie OKAY
    .m_axil_bvalid        (m_axil_bvalid),
    .m_axil_bready        (m_axil_bready),
    .m_axil_araddr        (m_axil_araddr),
    .m_axil_arvalid       (m_axil_arvalid),
    .m_axil_arready       (m_axil_arready),
    .m_axil_rdata         (m_axil_rdata),
    .m_axil_rresp         (m_axil_rresp),  // OKAY response; checked by xdma_regs (ignored)
    .m_axil_rvalid        (m_axil_rvalid),
    .m_axil_rready        (m_axil_rready)
  );

  // -------------------------------------------------------------------------
  // BAR0 register file
  // -------------------------------------------------------------------------
  xdma_regs u_regs (
    .clk             (user_clk),
    .rstn            (user_rstn),
    .s_axi_awaddr    (m_axil_awaddr),
    .s_axi_awvalid   (m_axil_awvalid),
    .s_axi_awready   (m_axil_awready),
    .s_axi_wdata     (m_axil_wdata),
    .s_axi_wvalid    (m_axil_wvalid),
    .s_axi_wready    (m_axil_wready),
    .s_axi_bvalid    (m_axil_bvalid),
    .s_axi_bready    (m_axil_bready),
    .s_axi_araddr    (m_axil_araddr),
    .s_axi_arvalid   (m_axil_arvalid),
    .s_axi_arready   (m_axil_arready),
    .s_axi_rdata     (m_axil_rdata),
    .s_axi_rvalid    (m_axil_rvalid),
    .s_axi_rready    (m_axil_rready),
    .hbm_ready_i     (hbm_ready_i),
    .eth10g_ready_i  (eth10g_ready_i),
    .hbm_done_i      (hbm_done_i),
    .hbm_any_error_i (hbm_any_error_i),
    .git_sha_lo_i    (git_sha_lo_i),
    .git_sha_hi_i    (git_sha_hi_i),
    .control_o        (control_o),
    .gpio_led_o       (gpio_led_o),
    .hbm_smoke_go_o   (hbm_smoke_go_o)
  );

endmodule
/* verilator lint_on UNUSEDSIGNAL */
