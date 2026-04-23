// SystemVerilog testbench for xdma_regs (Verilator-compatible).
`timescale 1ns/1ps
module xdma_regs_tb;

  // -------------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------------
  logic clk  = 0;
  logic rstn = 0;
  always #2 clk = ~clk; // 250 MHz

  // -------------------------------------------------------------------------
  // DUT signals
  // -------------------------------------------------------------------------
  logic [31:0] s_axi_awaddr  = '0;
  logic        s_axi_awvalid = 0;
  logic        s_axi_awready;
  logic [31:0] s_axi_wdata   = '0;
  logic        s_axi_wvalid  = 0;
  logic        s_axi_wready;
  logic        s_axi_bvalid;
  logic        s_axi_bready  = 0;
  logic [31:0] s_axi_araddr  = '0;
  logic        s_axi_arvalid = 0;
  logic        s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic        s_axi_rvalid;
  logic        s_axi_rready  = 0;
  logic        hbm_ready_i      = 0;
  logic        eth10g_ready_i   = 0;
  logic        hbm_done_i       = 0;
  logic        hbm_any_error_i  = 0;
  logic [31:0] git_sha_lo_i     = '0;
  logic [31:0] git_sha_hi_i     = '0;
  logic [2:0]  control_o;
  logic [3:0]  gpio_led_o;
  logic        hbm_smoke_go_o;

  xdma_regs dut (.*);

  // -------------------------------------------------------------------------
  // AXI-Lite helper tasks
  //
  // Protocol for a single-outstanding slave where arready and rvalid are
  // asserted simultaneously one cycle after arvalid is seen:
  //
  //   1. Drive arvalid + araddr on a negedge (setup time).
  //   2. Wait for arready to be sampled high at a posedge.
  //   3. On that same posedge, rvalid is also high; capture rdata.
  //   4. On the next negedge, de-assert arvalid and assert rready.
  //   5. One more posedge clears rvalid.
  // -------------------------------------------------------------------------

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    // -- AW phase --
    @(negedge clk);
    s_axi_awaddr  = addr;
    s_axi_awvalid = 1'b1;
    // awready is combinatorial (!aw_captured); wait for posedge where it's 1
    @(posedge clk);
    while (!s_axi_awready) @(posedge clk);
    // Handshake done at this posedge; de-assert on next negedge
    @(negedge clk);
    s_axi_awvalid = 1'b0;

    // -- W phase --
    @(negedge clk);
    s_axi_wdata  = data;
    s_axi_wvalid = 1'b1;
    @(posedge clk);
    while (!s_axi_wready) @(posedge clk);
    @(negedge clk);
    s_axi_wvalid = 1'b0;

    // -- B phase --
    @(negedge clk);
    s_axi_bready = 1'b1;
    @(posedge clk);
    while (!s_axi_bvalid) @(posedge clk);
    @(negedge clk);
    s_axi_bready = 1'b0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] out);
    // -- AR phase: arready and rvalid arrive in the same posedge --
    @(negedge clk);
    s_axi_araddr  = addr;
    s_axi_arvalid = 1'b1;
    @(posedge clk);
    while (!s_axi_arready) @(posedge clk);
    // arready=1 here; rvalid=1 here; capture data
    out = s_axi_rdata;
    @(negedge clk);
    s_axi_arvalid = 1'b0;
    s_axi_rready  = 1'b1;
    // One posedge to let rvalid clear (rready handshake)
    @(posedge clk);
    @(negedge clk);
    s_axi_rready  = 1'b0;
  endtask

  // -------------------------------------------------------------------------
  // Test body
  // -------------------------------------------------------------------------
  logic [31:0] rdata;
  int          fail_count = 0;

  initial begin
    // Reset for a few cycles
    repeat(4) @(posedge clk);
    @(negedge clk);
    rstn = 1'b1;
    repeat(2) @(posedge clk);

    // ------------------------------------------------------------------
    // Test 1: ID register
    // ------------------------------------------------------------------
    axi_read(32'h00, rdata);
    if (rdata !== 32'h4E414E4F) begin
      $display("FAIL: ID expected 0x4E414E4F, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: ID = 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Test 2: VERSION register
    // ------------------------------------------------------------------
    axi_read(32'h04, rdata);
    if (rdata !== 32'h0001_0000) begin
      $display("FAIL: VERSION expected 0x00010000, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: VERSION = 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Test 3: CONTROL round-trip (write 0x7, read back)
    // ------------------------------------------------------------------
    axi_write(32'h10, 32'h0000_0007);
    axi_read(32'h10, rdata);
    if (rdata !== 32'h0000_0007) begin
      $display("FAIL: CONTROL expected 0x00000007, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: CONTROL round-trip 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Test 4a: STATUS with both ready signals asserted
    // ------------------------------------------------------------------
    hbm_ready_i    = 1'b1;
    eth10g_ready_i = 1'b1;
    axi_read(32'h14, rdata);
    if (rdata !== 32'h0000_0003) begin
      $display("FAIL: STATUS[1:0] expected 0x00000003, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: STATUS[1:0] = 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Test 4b: STATUS with HBM smoke done + error bits
    // ------------------------------------------------------------------
    hbm_done_i      = 1'b1;
    hbm_any_error_i = 1'b1;
    axi_read(32'h14, rdata);
    // STATUS[9:8] = {hbm_any_error_i, hbm_done_i}; [1:0] = {eth10g_ready, hbm_ready}
    if (rdata !== 32'h0000_0303) begin
      $display("FAIL: STATUS[9:8] expected 0x00000303, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: STATUS with HBM smoke bits = 0x%08X", rdata);
    hbm_done_i      = 1'b0;
    hbm_any_error_i = 1'b0;

    // ------------------------------------------------------------------
    // Test 5: GIT_SHA_LO / GIT_SHA_HI
    // ------------------------------------------------------------------
    git_sha_lo_i = 32'h1234_5678;
    git_sha_hi_i = 32'h9ABC_DEF0;
    axi_read(32'h20, rdata);
    if (rdata !== 32'h1234_5678) begin
      $display("FAIL: GIT_SHA_LO expected 0x12345678, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: GIT_SHA_LO = 0x%08X", rdata);

    axi_read(32'h24, rdata);
    if (rdata !== 32'h9ABC_DEF0) begin
      $display("FAIL: GIT_SHA_HI expected 0x9ABCDEF0, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: GIT_SHA_HI = 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Test 6: Unknown address returns 0xDEAD_BEEF
    // ------------------------------------------------------------------
    axi_read(32'hFF, rdata);
    if (rdata !== 32'hDEAD_BEEF) begin
      $display("FAIL: unknown addr expected 0xDEADBEEF, got 0x%08X", rdata);
      fail_count++;
    end else
      $display("PASS: unknown addr = 0x%08X", rdata);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    if (fail_count == 0)
      $display("TB PASS");
    else
      $display("TB FAIL: %0d test(s) failed", fail_count);

    $finish;
  end

  // Timeout guard
  initial begin
    #100000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
