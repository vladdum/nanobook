// hw/ip/eth10g_wrapper/gty_10g_wrapper.sv
// Single-lane 10G-BASE-R over GTY (QSFP28 lane 0).
// Wraps Corundum eth_xcvr_phy_10g_gty_wrapper, exposes XGMII to loopback.
//
// NOTE: refclk must be a single-ended 156.25 MHz clock derived from an
// IBUFDS_GTE4 in the parent (or from the IBUFDS_GTE4 that is internal to
// the Corundum wrapper when HAS_COMMON=1).  For M1 we pass qsfp0_refclk_p
// directly; add an IBUFDS_GTE4 instantiation in nanobook_shell_top before
// the first real synthesis run.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module gty_10g_wrapper (
  input  wire        refclk,       // 156.25 MHz single-ended (from IBUFDS_GTE4)
  input  wire        sys_clk,      // system clock for ctrl
  input  wire        sys_rstn,

  // Serial lanes (QSFP28)
  input  wire        rx_p,
  input  wire        rx_n,
  output wire        tx_p,
  output wire        tx_n,

  // XGMII TX (from loopback → GTY)
  output wire        xgmii_tx_clk,
  output wire        xgmii_tx_rst,
  input  wire [63:0] xgmii_txd,
  input  wire  [7:0] xgmii_txc,

  // XGMII RX (from GTY → loopback)
  output wire        xgmii_rx_clk,
  output wire        xgmii_rx_rst,
  output wire [63:0] xgmii_rxd,
  output wire  [7:0] xgmii_rxc,

  // Status
  output wire        rx_locked    // phy_rx_block_lock
);

  // DRP tie-off (not needed for loopback)
  wire        drp_rdy;
  wire [15:0] drp_do;

  /* verilator lint_off PINCONNECTEMPTY */
  eth_xcvr_phy_10g_gty_wrapper #(
    .INDEX(0),
    .HAS_COMMON(1),
    .GT_USP(1),
    .DATA_WIDTH(64),
    .CTRL_WIDTH(8)
  ) gty_i (
    .xcvr_ctrl_clk          (sys_clk),
    .xcvr_ctrl_rst          (~sys_rstn),
    // Common (QPLL0) — HAS_COMMON=1 so these are outputs
    .xcvr_gtrefclk00_in     (refclk),
    .xcvr_qpll0pd_in        (1'b0),
    .xcvr_qpll0reset_in     (1'b0),
    .xcvr_qpll0pcierate_in  (3'b0),
    .xcvr_qpll0lock_out     (),
    .xcvr_qpll0clk_out      (),
    .xcvr_qpll0refclk_out   (),
    // QPLL1 — powered down
    .xcvr_gtrefclk01_in     (1'b0),
    .xcvr_qpll1pd_in        (1'b1),
    .xcvr_qpll1reset_in     (1'b0),
    .xcvr_qpll1pcierate_in  (3'b0),
    .xcvr_qpll1lock_out     (),
    .xcvr_qpll1clk_out      (),
    .xcvr_qpll1refclk_out   (),
    // PLL in (driven from common when HAS_COMMON=1; tie off here)
    .xcvr_qpll0lock_in      (1'b0),
    .xcvr_qpll0clk_in       (1'b0),
    .xcvr_qpll0refclk_in    (1'b0),
    .xcvr_qpll1lock_in      (1'b0),
    .xcvr_qpll1clk_in       (1'b0),
    .xcvr_qpll1refclk_in    (1'b0),
    // Serial
    .xcvr_txp               (tx_p),
    .xcvr_txn               (tx_n),
    .xcvr_rxp               (rx_p),
    .xcvr_rxn               (rx_n),
    // XGMII TX
    .phy_tx_clk             (xgmii_tx_clk),
    .phy_tx_rst             (xgmii_tx_rst),
    .phy_xgmii_txd          (xgmii_txd),
    .phy_xgmii_txc          (xgmii_txc),
    // XGMII RX
    .phy_rx_clk             (xgmii_rx_clk),
    .phy_rx_rst             (xgmii_rx_rst),
    .phy_xgmii_rxd          (xgmii_rxd),
    .phy_xgmii_rxc          (xgmii_rxc),
    // Status
    .phy_rx_block_lock      (rx_locked),
    // Unused status outputs
    .xcvr_gtpowergood_out   (),
    .phy_tx_bad_block       (),
    .phy_rx_error_count     (),
    .phy_rx_bad_block       (),
    .phy_rx_sequence_error  (),
    .phy_rx_high_ber        (),
    .phy_rx_status          (),
    // PRBS disabled
    .phy_cfg_tx_prbs31_enable(1'b0),
    .phy_cfg_rx_prbs31_enable(1'b0),
    // DRP tie-off
    .drp_clk                (sys_clk),
    .drp_rst                (~sys_rstn),
    .drp_addr               (24'b0),
    .drp_di                 (16'b0),
    .drp_en                 (1'b0),
    .drp_we                 (1'b0),
    .drp_do                 (drp_do),
    .drp_rdy                (drp_rdy)
  );
  /* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
endmodule
