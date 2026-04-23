`timescale 1ns/1ps
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDPARAM */
module eth_xcvr_phy_10g_gty_wrapper #(
  parameter INDEX = 0,
  parameter HAS_COMMON = 1,
  parameter GT_GTH = 0,
  parameter GT_USP = 1,
  parameter QPLL0_PD = 1'b0,
  parameter QPLL1_PD = 1'b1,
  parameter QPLL0_EXT_CTRL = 0,
  parameter QPLL1_EXT_CTRL = 0,
  parameter GT_TX_PD = 1'b0,
  parameter GT_TX_QPLL_SEL = 1'b0,
  parameter GT_TX_POLARITY = 1'b0,
  parameter GT_TX_ELECIDLE = 1'b0,
  parameter GT_TX_INHIBIT = 1'b0,
  parameter GT_TX_DIFFCTRL = 5'd16,
  parameter GT_TX_MAINCURSOR = 7'd64,
  parameter GT_TX_POSTCURSOR = 5'd0,
  parameter GT_TX_PRECURSOR = 5'd0,
  parameter GT_RX_PD = 1'b0,
  parameter GT_RX_QPLL_SEL = 1'b0,
  parameter GT_RX_LPM_EN = 1'b0,
  parameter GT_RX_POLARITY = 1'b0,
  parameter DATA_WIDTH = 64,
  parameter CTRL_WIDTH = (DATA_WIDTH/8),
  parameter HDR_WIDTH = 2,
  parameter PRBS31_ENABLE = 0,
  parameter TX_SERDES_PIPELINE = 0,
  parameter RX_SERDES_PIPELINE = 0,
  parameter BITSLIP_HIGH_CYCLES = 1,
  parameter BITSLIP_LOW_CYCLES = 8,
  parameter COUNT_125US = 125000/6.4
)(
  input  wire xcvr_ctrl_clk,
  input  wire xcvr_ctrl_rst,
  output wire xcvr_gtpowergood_out,
  input  wire drp_clk,
  input  wire drp_rst,
  input  wire [23:0] drp_addr,
  input  wire [15:0] drp_di,
  input  wire drp_en,
  input  wire drp_we,
  output wire [15:0] drp_do,
  output wire drp_rdy,
  input  wire xcvr_gtrefclk00_in,
  input  wire xcvr_qpll0pd_in,
  input  wire xcvr_qpll0reset_in,
  input  wire [2:0] xcvr_qpll0pcierate_in,
  output wire xcvr_qpll0lock_out,
  output wire xcvr_qpll0clk_out,
  output wire xcvr_qpll0refclk_out,
  input  wire xcvr_gtrefclk01_in,
  input  wire xcvr_qpll1pd_in,
  input  wire xcvr_qpll1reset_in,
  input  wire [2:0] xcvr_qpll1pcierate_in,
  output wire xcvr_qpll1lock_out,
  output wire xcvr_qpll1clk_out,
  output wire xcvr_qpll1refclk_out,
  input  wire xcvr_qpll0lock_in,
  input  wire xcvr_qpll0clk_in,
  input  wire xcvr_qpll0refclk_in,
  input  wire xcvr_qpll1lock_in,
  input  wire xcvr_qpll1clk_in,
  input  wire xcvr_qpll1refclk_in,
  output wire xcvr_txp,
  output wire xcvr_txn,
  input  wire xcvr_rxp,
  input  wire xcvr_rxn,
  output wire phy_tx_clk,
  output wire phy_tx_rst,
  input  wire [DATA_WIDTH-1:0] phy_xgmii_txd,
  input  wire [CTRL_WIDTH-1:0] phy_xgmii_txc,
  output wire phy_rx_clk,
  output wire phy_rx_rst,
  output wire [DATA_WIDTH-1:0] phy_xgmii_rxd,
  output wire [CTRL_WIDTH-1:0] phy_xgmii_rxc,
  output wire phy_tx_bad_block,
  output wire [6:0] phy_rx_error_count,
  output wire phy_rx_bad_block,
  output wire phy_rx_sequence_error,
  output wire phy_rx_block_lock,
  output wire phy_rx_high_ber,
  output wire phy_rx_status,
  input  wire phy_cfg_tx_prbs31_enable,
  input  wire phy_cfg_rx_prbs31_enable
);
  assign xcvr_gtpowergood_out  = 1'b0;
  assign drp_do                = 16'h0;
  assign drp_rdy               = 1'b0;
  assign xcvr_qpll0lock_out    = 1'b0;
  assign xcvr_qpll0clk_out     = 1'b0;
  assign xcvr_qpll0refclk_out  = 1'b0;
  assign xcvr_qpll1lock_out    = 1'b0;
  assign xcvr_qpll1clk_out     = 1'b0;
  assign xcvr_qpll1refclk_out  = 1'b0;
  assign xcvr_txp              = 1'b0;
  assign xcvr_txn              = 1'b0;
  assign phy_tx_clk            = 1'b0;
  assign phy_tx_rst            = 1'b0;
  assign phy_rx_clk            = 1'b0;
  assign phy_rx_rst            = 1'b0;
  assign phy_xgmii_rxd         = {DATA_WIDTH{1'b0}};
  assign phy_xgmii_rxc         = {CTRL_WIDTH{1'b0}};
  assign phy_tx_bad_block      = 1'b0;
  assign phy_rx_error_count    = 7'h0;
  assign phy_rx_bad_block      = 1'b0;
  assign phy_rx_sequence_error = 1'b0;
  assign phy_rx_block_lock     = 1'b0;
  assign phy_rx_high_ber       = 1'b0;
  assign phy_rx_status         = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on DECLFILENAME */
endmodule
