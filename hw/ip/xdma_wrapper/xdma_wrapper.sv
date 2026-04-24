// Thin wrapper around the Xilinx XDMA IP and the Nanobook BAR0 register file.
//
// Port list verified against the generated xdma_pcie.veo stub (Vivado 2025.2, XDMA 4.2).
// The XDMA m_axi_* DMA master ports are tied off — no host DMA slave in M1 shell.
// m_axil_* AXI-Lite master goes to xdma_regs for BAR0 register access.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module xdma_wrapper (
  // PCIe hard-block pins
  input  wire         pcie_refclk_p,
  input  wire         pcie_refclk_n,
  input  wire         pcie_rstn,
  input  wire  [3:0]  pcie_rx_p,
  input  wire  [3:0]  pcie_rx_n,
  output wire  [3:0]  pcie_tx_p,
  output wire  [3:0]  pcie_tx_n,

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
  // PCIe reference clock buffer (IBUFDS_GTE4 — required by XDMA 4.2 in 2025.2)
  // sys_clk_gt = direct GT refclk; sys_clk = ODIV2 (÷2) for logic
  // -------------------------------------------------------------------------
  wire pcie_refclk_gt;
  wire pcie_refclk_se;
  IBUFDS_GTE4 #(
    .REFCLK_HROW_CK_SEL(2'b00)
  ) u_ibufds_pcie (
    .I    (pcie_refclk_p),
    .IB   (pcie_refclk_n),
    .CEB  (1'b0),
    .O    (pcie_refclk_gt),
    .ODIV2(pcie_refclk_se)
  );

  // -------------------------------------------------------------------------
  // AXI-Lite master wires from XDMA to xdma_regs
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
  logic        m_axil_rvalid;
  logic        m_axil_rready;

  // -------------------------------------------------------------------------
  // Xilinx XDMA IP instantiation (XDMA 4.2, Vivado 2025.2)
  // m_axi_* DMA master tied off — no host memory in M1 shell
  // -------------------------------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  xdma_pcie u_xdma (
    // PCIe GT
    .pci_exp_rxp          (pcie_rx_p),
    .pci_exp_rxn          (pcie_rx_n),
    .pci_exp_txp          (pcie_tx_p),
    .pci_exp_txn          (pcie_tx_n),
    // Reference clocks from IBUFDS_GTE4
    .sys_clk              (pcie_refclk_se),
    .sys_clk_gt           (pcie_refclk_gt),
    // Active-low reset from PCIe connector
    .sys_rst_n            (pcie_rstn),
    // User clock / reset outputs
    .axi_aclk             (user_clk),
    .axi_aresetn          (user_rstn),
    // PCIe link status / interrupt (floated — not used in M1 shell)
    .user_lnk_up          (),
    .usr_irq_req          (1'b0),
    .usr_irq_ack          (),
    .msi_enable           (),
    .msi_vector_width     (),
    // PCIe config management (tied off — not used in M1 shell)
    .cfg_mgmt_addr        (19'h0),
    .cfg_mgmt_write       (1'b0),
    .cfg_mgmt_write_data  (32'h0),
    .cfg_mgmt_byte_enable (4'h0),
    .cfg_mgmt_read        (1'b0),
    .cfg_mgmt_read_data   (),
    .cfg_mgmt_read_write_done(),
    // AXI-Lite master (BAR0 → xdma_regs)
    .m_axil_awaddr        (m_axil_awaddr),
    .m_axil_awprot        (),
    .m_axil_awvalid       (m_axil_awvalid),
    .m_axil_awready       (m_axil_awready),
    .m_axil_wdata         (m_axil_wdata),
    .m_axil_wstrb         (),
    .m_axil_wvalid        (m_axil_wvalid),
    .m_axil_wready        (m_axil_wready),
    .m_axil_bresp         (2'b00),
    .m_axil_bvalid        (m_axil_bvalid),
    .m_axil_bready        (m_axil_bready),
    .m_axil_araddr        (m_axil_araddr),
    .m_axil_arprot        (),
    .m_axil_arvalid       (m_axil_arvalid),
    .m_axil_arready       (m_axil_arready),
    .m_axil_rdata         (m_axil_rdata),
    .m_axil_rresp         (2'b00),
    .m_axil_rvalid        (m_axil_rvalid),
    .m_axil_rready        (m_axil_rready),
    // AXI4 DMA master — tied off (no host DMA in M1 shell)
    .m_axi_awready        (1'b0),
    .m_axi_wready         (1'b0),
    .m_axi_bid            (4'h0),
    .m_axi_bresp          (2'b00),
    .m_axi_bvalid         (1'b0),
    .m_axi_arready        (1'b0),
    .m_axi_rid            (4'h0),
    .m_axi_rdata          (256'h0),
    .m_axi_rresp          (2'b00),
    .m_axi_rlast          (1'b0),
    .m_axi_rvalid         (1'b0),
    // AXI4 DMA master outputs — floated (nothing to connect to in M1 shell)
    .m_axi_awid           (),
    .m_axi_awaddr         (),
    .m_axi_awlen          (),
    .m_axi_awsize         (),
    .m_axi_awburst        (),
    .m_axi_awprot         (),
    .m_axi_awvalid        (),
    .m_axi_awlock         (),
    .m_axi_awcache        (),
    .m_axi_wdata          (),
    .m_axi_wstrb          (),
    .m_axi_wlast          (),
    .m_axi_wvalid         (),
    .m_axi_bready         (),
    .m_axi_arid           (),
    .m_axi_araddr         (),
    .m_axi_arlen          (),
    .m_axi_arsize         (),
    .m_axi_arburst        (),
    .m_axi_arprot         (),
    .m_axi_arvalid        (),
    .m_axi_arlock         (),
    .m_axi_arcache        (),
    .m_axi_rready         ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

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
