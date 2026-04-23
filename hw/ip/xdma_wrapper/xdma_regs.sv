// BAR0 register file for the Nanobook XDMA wrapper.
// Implements a minimal AXI-Lite slave (single-outstanding) with the frozen
// M1 register map.  Only CONTROL (0x10) is writable; all other offsets that
// are not listed return 0xDEAD_BEEF on read.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module xdma_regs #(
  parameter logic [31:0] ID      = 32'h4E414E4F,
  parameter logic [31:0] VERSION = 32'h0001_0000
)(
  input  logic        clk,
  input  logic        rstn,
  // AXI-Lite slave (32-bit address, 32-bit data)
  input  logic [31:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,
  input  logic [31:0] s_axi_wdata,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,
  input  logic [31:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,
  // Status inputs
  input  logic        hbm_ready_i,
  input  logic        eth10g_ready_i,
  input  logic        hbm_done_i,
  input  logic        hbm_any_error_i,
  // SHA inputs
  input  logic [31:0] git_sha_lo_i,
  input  logic [31:0] git_sha_hi_i,
  // Control outputs
  output logic [2:0]  control_o,    // [0]=enable, [1]=reset, [2]=pause
  output logic [3:0]  gpio_led_o,   // CONTROL[6:3]
  output logic        hbm_smoke_go_o // CONTROL[4]
);
/* verilator lint_on UNUSEDSIGNAL */

  // -------------------------------------------------------------------------
  // Internal register storage
  // -------------------------------------------------------------------------
  logic [6:0] control_reg;

  assign control_o       = control_reg[2:0];
  assign hbm_smoke_go_o  = control_reg[4];
  assign gpio_led_o      = control_reg[6:3];

  // -------------------------------------------------------------------------
  // Write channel – single-outstanding.
  // AW and W are captured independently; B is issued when both are captured.
  // -------------------------------------------------------------------------
  logic       aw_captured;
  logic [7:0] aw_addr_q;   // only [7:0] used for decode
  logic       w_captured;
  logic [6:0] w_data_q;    // only [6:0] written to control_reg

  assign s_axi_awready = !aw_captured;
  assign s_axi_wready  = !w_captured;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      aw_captured  <= 1'b0;
      aw_addr_q    <= '0;
      w_captured   <= 1'b0;
      w_data_q     <= '0;
      s_axi_bvalid <= 1'b0;
      control_reg  <= '0;
    end else begin
      // Capture AW (only when not already captured)
      if (s_axi_awvalid && !aw_captured) begin
        aw_captured <= 1'b1;
        aw_addr_q   <= s_axi_awaddr[7:0];
      end
      // Capture W (only when not already captured)
      if (s_axi_wvalid && !w_captured) begin
        w_captured <= 1'b1;
        w_data_q   <= s_axi_wdata[6:0];
      end
      // When both captured and B not yet pending: execute write, issue B
      if (!s_axi_bvalid) begin
        if (aw_captured && w_captured) begin
          if (aw_addr_q == 8'h10)
            control_reg <= w_data_q;
          s_axi_bvalid <= 1'b1;
          aw_captured  <= 1'b0;
          w_captured   <= 1'b0;
        end
      end else begin
        // Clear B once accepted
        if (s_axi_bready)
          s_axi_bvalid <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Read channel – single-outstanding.
  // State: IDLE → RESP
  // In IDLE: accept AR and move to RESP.
  // In RESP: hold rvalid until rready, then return to IDLE.
  // -------------------------------------------------------------------------
  typedef enum logic { RD_IDLE = 1'b0, RD_RESP = 1'b1 } rd_state_t;
  rd_state_t rd_state;

  // Decode read data combinatorially so it is stable in RESP
  logic [31:0] rd_data_nxt;
  always_comb begin
    unique case (s_axi_araddr[7:0])
      8'h00:   rd_data_nxt = ID;
      8'h04:   rd_data_nxt = VERSION;
      8'h10:   rd_data_nxt = {25'h0, control_reg};
      8'h14:   rd_data_nxt = {22'h0, hbm_any_error_i, hbm_done_i, 6'h0, eth10g_ready_i, hbm_ready_i};
      8'h20:   rd_data_nxt = git_sha_lo_i;
      8'h24:   rd_data_nxt = git_sha_hi_i;
      default: rd_data_nxt = 32'hDEAD_BEEF;
    endcase
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      rd_state      <= RD_IDLE;
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= '0;
    end else begin
      s_axi_arready <= 1'b0; // default: pulse for one cycle only
      case (rd_state)
        RD_IDLE: begin
          if (s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            s_axi_rdata   <= rd_data_nxt;
            s_axi_rvalid  <= 1'b1;
            rd_state      <= RD_RESP;
          end
        end
        RD_RESP: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            rd_state     <= RD_IDLE;
          end
        end
      endcase
    end
  end

endmodule
