// Thin wrapper around the Xilinx HBM IP with an integrated M1 smoke-test
// traffic generator.
//
// NOTE: HBM IP port names below follow the PG276 / Vivado 2024.2 naming
//       convention.  Verify against the generated .veo stub before the first
//       build: run `generate_target simulation` in hbm.tcl to produce it.
//
// For Verilator lint purposes the hbm module is provided by hw/lint/hbm_stub.sv.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module hbm_wrapper (
  // HBM reference clock (differential, 100 MHz → 10 000 ps period)
  input  wire  hbm_refclk_p,
  input  wire  hbm_refclk_n,
  // User-domain clock and active-high reset (250 MHz, from XDMA)
  input  wire  user_clk,
  input  wire  user_rstn,
  // Smoke-test control (from BAR0 CONTROL[4])
  input  logic smoke_go,
  output logic smoke_done,
  output logic smoke_any_error,
  // HBM calibration / ready status
  output wire  hbm_ready
);
/* verilator lint_on UNUSEDSIGNAL */

  // -------------------------------------------------------------------------
  // Internal AXI4 wires between traffic generator and HBM IP port 0
  // -------------------------------------------------------------------------
  localparam int AXI_DATA_W = 256;
  localparam int AXI_ADDR_W = 33;

  logic [7:0]              tg_awid;
  logic [AXI_ADDR_W-1:0]  tg_awaddr;
  logic [7:0]              tg_awlen;
  logic [2:0]              tg_awsize;
  logic [1:0]              tg_awburst;
  logic                    tg_awvalid;
  logic                    tg_awready;
  logic [AXI_DATA_W-1:0]  tg_wdata;
  logic [AXI_DATA_W/8-1:0] tg_wstrb;
  logic                    tg_wlast;
  logic                    tg_wvalid;
  logic                    tg_wready;
  logic [7:0]              tg_bid;
  logic [1:0]              tg_bresp;
  logic                    tg_bvalid;
  logic                    tg_bready;
  logic [7:0]              tg_arid;
  logic [AXI_ADDR_W-1:0]  tg_araddr;
  logic [7:0]              tg_arlen;
  logic [2:0]              tg_arsize;
  logic [1:0]              tg_arburst;
  logic                    tg_arvalid;
  logic                    tg_arready;
  logic [7:0]              tg_rid;
  logic [AXI_DATA_W-1:0]  tg_rdata;
  logic [1:0]              tg_rresp;
  logic                    tg_rlast;
  logic                    tg_rvalid;
  logic                    tg_rready;

  logic [31:0] tg_axi_errors;
  logic [31:0] tg_data_mismatches;

  // smoke_any_error is asserted if either error counter is non-zero once done
  always_ff @(posedge user_clk or negedge user_rstn) begin
    if (!user_rstn) begin
      smoke_done      <= 1'b0;
      smoke_any_error <= 1'b0;
    end else begin
      smoke_done      <= tg_done;
      smoke_any_error <= tg_done && ((tg_axi_errors != '0) || (tg_data_mismatches != '0));
    end
  end

  logic tg_done;

  // -------------------------------------------------------------------------
  // Traffic generator: 16 MB write + readback (hardcoded for M1 smoke test)
  // -------------------------------------------------------------------------
  hbm_traffic_gen #(
    .AXI_DATA_W (AXI_DATA_W),
    .AXI_ADDR_W (AXI_ADDR_W),
    .BURST_LEN  (16)
  ) u_tg (
    .clk             (user_clk),
    .rstn            (user_rstn),
    .start           (smoke_go),
    .num_bytes       (32'd16_777_216), // 16 MB
    .done            (tg_done),
    .axi_errors      (tg_axi_errors),
    .data_mismatches (tg_data_mismatches),
    // AW
    .m_axi_awid      (tg_awid),
    .m_axi_awaddr    (tg_awaddr),
    .m_axi_awlen     (tg_awlen),
    .m_axi_awsize    (tg_awsize),
    .m_axi_awburst   (tg_awburst),
    .m_axi_awvalid   (tg_awvalid),
    .m_axi_awready   (tg_awready),
    // W
    .m_axi_wdata     (tg_wdata),
    .m_axi_wstrb     (tg_wstrb),
    .m_axi_wlast     (tg_wlast),
    .m_axi_wvalid    (tg_wvalid),
    .m_axi_wready    (tg_wready),
    // B
    .m_axi_bid       (tg_bid),
    .m_axi_bresp     (tg_bresp),
    .m_axi_bvalid    (tg_bvalid),
    .m_axi_bready    (tg_bready),
    // AR
    .m_axi_arid      (tg_arid),
    .m_axi_araddr    (tg_araddr),
    .m_axi_arlen     (tg_arlen),
    .m_axi_arsize    (tg_arsize),
    .m_axi_arburst   (tg_arburst),
    .m_axi_arvalid   (tg_arvalid),
    .m_axi_arready   (tg_arready),
    // R
    .m_axi_rid       (tg_rid),
    .m_axi_rdata     (tg_rdata),
    .m_axi_rresp     (tg_rresp),
    .m_axi_rlast     (tg_rlast),
    .m_axi_rvalid    (tg_rvalid),
    .m_axi_rready    (tg_rready)
  );

  // -------------------------------------------------------------------------
  // HBM IP instantiation
  // Port names per PG276 / generated stub — verify with .veo before build.
  // HBM reference clock differential pair fed through IBUFDS inside the IP.
  // apb_complete_0/1 indicate that the APB init sequence is done (i.e. HBM ready).
  // -------------------------------------------------------------------------
  logic apb_complete_0;
  logic apb_complete_1;
  assign hbm_ready = apb_complete_0 & apb_complete_1;

  hbm u_hbm (
    // Reference clocks
    .HBM_REF_CLK_0    (hbm_refclk_p),  // stack 0; IBUFDS inside IP
    .HBM_REF_CLK_1    (hbm_refclk_n),  // stack 1 (or N-side of diff pair — check PG276 §3)
    // AXI port 0 — traffic generator
    .AXI_00_ACLK      (user_clk),
    .AXI_00_ARESET_N  (user_rstn),
    .AXI_00_AWID      (tg_awid),
    .AXI_00_AWADDR    (tg_awaddr),
    .AXI_00_AWLEN     (tg_awlen),
    .AXI_00_AWSIZE    (tg_awsize),
    .AXI_00_AWBURST   (tg_awburst),
    .AXI_00_AWVALID   (tg_awvalid),
    .AXI_00_AWREADY   (tg_awready),
    .AXI_00_WDATA     (tg_wdata),
    .AXI_00_WSTRB     (tg_wstrb),
    .AXI_00_WLAST     (tg_wlast),
    .AXI_00_WVALID    (tg_wvalid),
    .AXI_00_WREADY    (tg_wready),
    .AXI_00_BID       (tg_bid),
    .AXI_00_BRESP     (tg_bresp),
    .AXI_00_BVALID    (tg_bvalid),
    .AXI_00_BREADY    (tg_bready),
    .AXI_00_ARID      (tg_arid),
    .AXI_00_ARADDR    (tg_araddr),
    .AXI_00_ARLEN     (tg_arlen),
    .AXI_00_ARSIZE    (tg_arsize),
    .AXI_00_ARBURST   (tg_arburst),
    .AXI_00_ARVALID   (tg_arvalid),
    .AXI_00_ARREADY   (tg_arready),
    .AXI_00_RID       (tg_rid),
    .AXI_00_RDATA     (tg_rdata),
    .AXI_00_RRESP     (tg_rresp),
    .AXI_00_RLAST     (tg_rlast),
    .AXI_00_RVALID    (tg_rvalid),
    .AXI_00_RREADY    (tg_rready),
    // Calibration complete
    .apb_complete_0   (apb_complete_0),
    .apb_complete_1   (apb_complete_1)
  );

endmodule
