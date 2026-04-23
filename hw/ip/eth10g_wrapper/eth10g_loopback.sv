// hw/ip/eth10g_wrapper/eth10g_loopback.sv
// Single-cycle XGMII loopback: RX frame echoed as TX.
`timescale 1ns/1ps

module eth10g_loopback (
  input  logic        clk,
  input  logic        rst,

  // From GTY RX
  input  logic [63:0] xgmii_rxd,
  input  logic  [7:0] xgmii_rxc,

  // To GTY TX
  output logic [63:0] xgmii_txd,
  output logic  [7:0] xgmii_txc
);
  always_ff @(posedge clk) begin
    if (rst) begin
      xgmii_txd <= 64'h0707070707070707; // XGMII idle
      xgmii_txc <= 8'hFF;
    end else begin
      xgmii_txd <= xgmii_rxd;
      xgmii_txc <= xgmii_rxc;
    end
  end
endmodule
