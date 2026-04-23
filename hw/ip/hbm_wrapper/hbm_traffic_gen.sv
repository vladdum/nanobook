// HBM AXI4 traffic generator for M1 smoke test.
// FSM: IDLE → WRITE → WAIT_B → READ → WAIT_R → DONE_S
// Write phase: streams BURST_LEN-beat bursts across [0, num_bytes).
// Read phase:  reads back same range and compares against expected pattern.
// Pattern:    word at beat index i = {8{i[4:0], 3'b0}} across the 256-bit word.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDSIGNAL */
module hbm_traffic_gen #(
  parameter int AXI_DATA_W = 256,
  parameter int AXI_ADDR_W = 33,
  parameter int BURST_LEN  = 16
)(
  input  logic        clk,
  input  logic        rstn,
  input  logic        start,
  input  logic [31:0] num_bytes,
  output logic        done,
  output logic [31:0] axi_errors,
  output logic [31:0] data_mismatches,
  // AXI4 master (full handshake)
  output logic [7:0]               m_axi_awid,
  output logic [AXI_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]               m_axi_awlen,
  output logic [2:0]               m_axi_awsize,
  output logic [1:0]               m_axi_awburst,
  output logic                     m_axi_awvalid,
  input  logic                     m_axi_awready,
  output logic [AXI_DATA_W-1:0]   m_axi_wdata,
  output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
  output logic                     m_axi_wlast,
  output logic                     m_axi_wvalid,
  input  logic                     m_axi_wready,
  input  logic [7:0]               m_axi_bid,
  input  logic [1:0]               m_axi_bresp,
  input  logic                     m_axi_bvalid,
  output logic                     m_axi_bready,
  output logic [7:0]               m_axi_arid,
  output logic [AXI_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]               m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,
  input  logic [7:0]               m_axi_rid,
  input  logic [AXI_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready
);
/* verilator lint_on UNUSEDSIGNAL */

  // -------------------------------------------------------------------------
  // Local parameters
  // -------------------------------------------------------------------------
  localparam int BYTES_PER_BEAT  = AXI_DATA_W / 8;   // 32
  localparam int BYTES_PER_BURST = BYTES_PER_BEAT * BURST_LEN; // 512
  // AXI size field: log2(BYTES_PER_BEAT)
  localparam logic [2:0] AXI_SIZE = 3'($clog2(BYTES_PER_BEAT));

  // -------------------------------------------------------------------------
  // FSM states
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    IDLE   = 3'd0,
    WRITE  = 3'd1,
    WAIT_B = 3'd2,
    READ   = 3'd3,
    WAIT_R = 3'd4,
    DONE_S = 3'd5
  } state_t;

  state_t state;

  // -------------------------------------------------------------------------
  // Address and beat counters
  // -------------------------------------------------------------------------
  logic [AXI_ADDR_W-1:0] cur_addr;   // current burst base address
  logic [7:0]             beat_cnt;   // within-burst beat counter (0 .. BURST_LEN-1)
  logic [AXI_ADDR_W-1:0] end_addr;   // exclusive end address

  // -------------------------------------------------------------------------
  // Pattern generation
  // -------------------------------------------------------------------------
  // Pattern for beat index b: byte value = (b[4:0] << 3) for each byte lane.
  // We track global beat index for pattern generation.
  logic [AXI_ADDR_W-1:0] wr_beat_addr; // address of current write beat
  logic [AXI_ADDR_W-1:0] rd_beat_addr; // address of current read beat

  // beat_base_addr bits [4+log2(BPB):log2(BPB)] give the 5-bit beat index within
  // a 32-beat window.  BYTES_PER_BEAT=32 so log2=5; the index occupies bits [9:5].
  // All other bits are intentionally unused — suppress the lint warning locally.
  function automatic logic [AXI_DATA_W-1:0] beat_pattern(
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [AXI_ADDR_W-1:0] beat_base_addr
    /* verilator lint_on UNUSEDSIGNAL */
  );
    logic [4:0] idx;
    logic [7:0] bval;
    idx  = beat_base_addr[9:5]; // bits [4+log2(32) : log2(32)] = [9:5]
    bval = {idx, 3'b0};
    for (int b = 0; b < BYTES_PER_BEAT; b++)
      beat_pattern[b*8 +: 8] = bval;
  endfunction

  // -------------------------------------------------------------------------
  // Sequential logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state            <= IDLE;
      done             <= 1'b0;
      axi_errors       <= '0;
      data_mismatches  <= '0;
      cur_addr         <= '0;
      beat_cnt         <= '0;
      wr_beat_addr     <= '0;
      rd_beat_addr     <= '0;
      end_addr         <= '0;
      // AW channel
      m_axi_awid       <= '0;
      m_axi_awaddr     <= '0;
      m_axi_awlen      <= '0;
      m_axi_awsize     <= '0;
      m_axi_awburst    <= 2'b01; // INCR
      m_axi_awvalid    <= 1'b0;
      // W channel
      m_axi_wdata      <= '0;
      m_axi_wstrb      <= '1;
      m_axi_wlast      <= 1'b0;
      m_axi_wvalid     <= 1'b0;
      // B channel
      m_axi_bready     <= 1'b1;
      // AR channel
      m_axi_arid       <= '0;
      m_axi_araddr     <= '0;
      m_axi_arlen      <= '0;
      m_axi_arsize     <= '0;
      m_axi_arburst    <= 2'b01; // INCR
      m_axi_arvalid    <= 1'b0;
      // R channel
      m_axi_rready     <= 1'b1;
    end else begin
      case (state)

        // --------------------------------------------------------------------
        IDLE: begin
          done             <= 1'b0;
          axi_errors       <= '0;
          data_mismatches  <= '0;
          m_axi_awvalid    <= 1'b0;
          m_axi_wvalid     <= 1'b0;
          m_axi_arvalid    <= 1'b0;
          m_axi_bready     <= 1'b1;
          m_axi_rready     <= 1'b1;
          if (start) begin
            cur_addr     <= '0;
            wr_beat_addr <= '0;
            end_addr     <= AXI_ADDR_W'(num_bytes);
            beat_cnt     <= '0;
            // Issue first AW
            m_axi_awaddr  <= '0;
            m_axi_awlen   <= 8'(BURST_LEN - 1);
            m_axi_awsize  <= AXI_SIZE;
            m_axi_awburst <= 2'b01;
            m_axi_awvalid <= 1'b1;
            // First W beat
            m_axi_wdata   <= beat_pattern('0);
            m_axi_wstrb   <= '1;
            m_axi_wlast   <= (BURST_LEN == 1) ? 1'b1 : 1'b0;
            m_axi_wvalid  <= 1'b1;
            state         <= WRITE;
          end
        end

        // --------------------------------------------------------------------
        WRITE: begin
          // -- AW handshake --
          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
          end

          // -- W handshake --
          if (m_axi_wvalid && m_axi_wready) begin
            wr_beat_addr  <= wr_beat_addr + AXI_ADDR_W'(BYTES_PER_BEAT);
            beat_cnt      <= beat_cnt + 8'd1;
            if (m_axi_wlast) begin
              // Burst complete — go wait for B
              m_axi_wvalid <= 1'b0;
              m_axi_wlast  <= 1'b0;
              beat_cnt     <= '0;
              cur_addr     <= cur_addr + AXI_ADDR_W'(BYTES_PER_BURST);
              state        <= WAIT_B;
            end else begin
              // Next beat — compute address inline (no local var in always_ff)
              m_axi_wdata  <= beat_pattern(wr_beat_addr + AXI_ADDR_W'(BYTES_PER_BEAT));
              m_axi_wlast  <= (beat_cnt + 8'd2 == 8'(BURST_LEN));
            end
          end
        end

        // --------------------------------------------------------------------
        WAIT_B: begin
          if (m_axi_bvalid) begin
            if (m_axi_bresp != 2'b00)
              axi_errors <= axi_errors + 32'd1;
            if (cur_addr >= end_addr) begin
              // All writes complete — start read phase
              cur_addr     <= '0;
              rd_beat_addr <= '0;
              beat_cnt     <= '0;
              // Issue first AR
              m_axi_araddr  <= '0;
              m_axi_arlen   <= 8'(BURST_LEN - 1);
              m_axi_arsize  <= AXI_SIZE;
              m_axi_arburst <= 2'b01;
              m_axi_arvalid <= 1'b1;
              state         <= READ;
            end else begin
              // Issue next AW + W
              m_axi_awaddr  <= cur_addr;
              m_axi_awlen   <= 8'(BURST_LEN - 1);
              m_axi_awsize  <= AXI_SIZE;
              m_axi_awvalid <= 1'b1;
              m_axi_wdata   <= beat_pattern(cur_addr);
              m_axi_wstrb   <= '1;
              m_axi_wlast   <= (BURST_LEN == 1) ? 1'b1 : 1'b0;
              m_axi_wvalid  <= 1'b1;
              state         <= WRITE;
            end
          end
        end

        // --------------------------------------------------------------------
        READ: begin
          // -- AR handshake --
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
          end

          // -- R handshake --
          if (m_axi_rvalid && m_axi_rready) begin
            // Check response
            if (m_axi_rresp != 2'b00)
              axi_errors <= axi_errors + 32'd1;
            // Check data
            if (m_axi_rdata !== beat_pattern(rd_beat_addr))
              data_mismatches <= data_mismatches + 32'd1;
            rd_beat_addr <= rd_beat_addr + AXI_ADDR_W'(BYTES_PER_BEAT);
            beat_cnt     <= beat_cnt + 8'd1;
            if (m_axi_rlast) begin
              beat_cnt <= '0;
              cur_addr <= cur_addr + AXI_ADDR_W'(BYTES_PER_BURST);
              state    <= WAIT_R;
            end
          end
        end

        // --------------------------------------------------------------------
        WAIT_R: begin
          if (cur_addr >= end_addr) begin
            state <= DONE_S;
          end else begin
            // Issue next AR
            m_axi_araddr  <= cur_addr;
            m_axi_arlen   <= 8'(BURST_LEN - 1);
            m_axi_arsize  <= AXI_SIZE;
            m_axi_arburst <= 2'b01;
            m_axi_arvalid <= 1'b1;
            state         <= READ;
          end
        end

        // --------------------------------------------------------------------
        DONE_S: begin
          done  <= 1'b1;
          state <= DONE_S; // hold until reset
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
