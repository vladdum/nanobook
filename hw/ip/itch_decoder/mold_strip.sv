// SPDX-License-Identifier: Apache-2.0
// mold_strip — pipeline stage 1: strip 20-byte MoldUDP64 header from
// every input packet. Captures sequence number for gap detection and
// holds TUSER (ingress_ts) on the first post-header beat.
//
// MoldUDP64 header layout (20 bytes):
//   session[0:9]     ASCII session identifier (10 bytes)
//   sequence[10:17]  uint64, big-endian
//   msg_count[18:19] uint16, big-endian
//
// All input/output beats are 64-bit. The MoldUDP header is 20 bytes =
// 2.5 beats; the third beat carries the last 4 bytes of header + first 4
// bytes of payload. We use a 1-cycle holdover register to splice the
// payload portion of the third beat with the next beat.

module mold_strip #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic              clk,
    input  logic              rstn,

    // Input from udp_parser (post-L2/L3/L4 strip)
    input  logic [DATA_W-1:0]   s_tdata,
    input  logic [DATA_W/8-1:0] s_tkeep,
    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic                s_tlast,
    input  logic [TS_W-1:0]     s_tuser,

    // Output: payload only (post-header), TUSER on first beat
    output logic [DATA_W-1:0]   m_tdata,
    output logic [DATA_W/8-1:0] m_tkeep,
    output logic                m_tvalid,
    input  logic                m_tready,
    output logic                m_tlast,
    output logic [TS_W-1:0]     m_tuser,

    // Stat counter
    output logic [31:0]         mold_seq_gap
);
    // States: scanning header beats vs forwarding payload.
    typedef enum logic [1:0] {
        ST_HEADER_BEAT0,  // bytes 0..7   (session lo)
        ST_HEADER_BEAT1,  // bytes 8..15  (session hi + seq lo)
        ST_HEADER_BEAT2,  // bytes 16..23 (seq hi + msg_count + first 4B payload)
        ST_PAYLOAD        // remaining beats
    } state_e;

    state_e state;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] seq_acc;        // accumulated seq number from beats 1+2
    /* verilator lint_on UNUSEDSIGNAL */
    logic [63:0] expected_next_seq;
    logic [31:0] gap_count_q;
    logic        first_packet;
    logic [TS_W-1:0] held_tuser;
    logic [DATA_W-1:0] held_data;
    logic [DATA_W/8-1:0] held_keep;

    // Output registers
    logic [DATA_W-1:0]    m_tdata_q;
    logic [DATA_W/8-1:0]  m_tkeep_q;
    logic                 m_tvalid_q;
    logic                 m_tlast_q;
    logic [TS_W-1:0]      m_tuser_q;

    assign m_tdata        = m_tdata_q;
    assign m_tkeep        = m_tkeep_q;
    assign m_tvalid       = m_tvalid_q;
    assign m_tlast        = m_tlast_q;
    assign m_tuser        = m_tuser_q;
    assign mold_seq_gap   = gap_count_q;
    assign s_tready       = m_tready;  // 1-cycle backpressure pass-through

    always_ff @(posedge clk) begin
        if (!rstn) begin
            state             <= ST_HEADER_BEAT0;
            seq_acc           <= '0;
            expected_next_seq <= '0;
            gap_count_q       <= '0;
            first_packet      <= 1'b1;
            held_tuser        <= '0;
            held_data         <= '0;
            held_keep         <= '0;
            m_tvalid_q        <= 1'b0;
            m_tlast_q         <= 1'b0;
            m_tdata_q         <= '0;
            m_tkeep_q         <= '0;
            m_tuser_q         <= '0;
        end else begin
            m_tvalid_q <= 1'b0;
            m_tlast_q  <= 1'b0;
            if (s_tvalid && s_tready) begin
                case (state)
                    ST_HEADER_BEAT0: begin
                        // session bytes 0..7 — discard. Capture TUSER.
                        held_tuser <= s_tuser;
                        state      <= ST_HEADER_BEAT1;
                    end
                    ST_HEADER_BEAT1: begin
                        // bytes 8..9 = session hi (discard); bytes 10..15 = seq[63:16]
                        // AXI-S is little-endian byte-lane (byte 0 in TDATA[7:0]),
                        // ITCH/MoldUDP fields are big-endian — byte-swap on read.
                        seq_acc[63:16] <= {s_tdata[23:16], s_tdata[31:24],
                                           s_tdata[39:32], s_tdata[47:40],
                                           s_tdata[55:48], s_tdata[63:56]};
                        state          <= ST_HEADER_BEAT2;
                    end
                    ST_HEADER_BEAT2: begin
                        // bytes 16..17 = seq[15:0] (big-endian); bytes 18..19 = msg_count;
                        // bytes 20..23 = first 4 payload bytes.
                        seq_acc[15:0] <= {s_tdata[7:0], s_tdata[15:8]};
                        held_data     <= {32'h0, s_tdata[63:32]};
                        held_keep     <= 8'h0F;  // 4 valid bytes
                        state         <= ST_PAYLOAD;
                        // Sequence-gap detection. seq_acc[63:16] is the upper 48
                        // bits (already byte-swapped on capture); the byte-swap of
                        // s_tdata[15:0] gives the lower 16 bits. Concat MSB-first.
                        if (!first_packet
                            && {seq_acc[63:16], s_tdata[7:0], s_tdata[15:8]} != expected_next_seq) begin
                            gap_count_q <= gap_count_q + 32'd1;
                        end
                        // Note: msg_count would refine expected_next_seq;
                        // for M03 we just track per-packet (one-msg PCAPs are common).
                        expected_next_seq <= {seq_acc[63:16], s_tdata[7:0], s_tdata[15:8]} + 64'd1;
                        first_packet      <= 1'b0;
                    end
                    ST_PAYLOAD: begin
                        // Forward this beat after splicing it with held_data.
                        m_tdata_q  <= {s_tdata[31:0], held_data[31:0]};
                        m_tkeep_q  <= {s_tkeep[3:0],  held_keep[3:0]};
                        m_tvalid_q <= 1'b1;
                        m_tuser_q  <= held_tuser;
                        held_tuser <= '0;  // emit only on first payload beat
                        held_data  <= {32'h0, s_tdata[63:32]};
                        held_keep  <= {4'h0, s_tkeep[7:4]};
                        if (s_tlast && (s_tkeep[7:4] == 4'h0)) begin
                            // No upper-4 bytes carried over — TLAST in this output beat.
                            m_tlast_q  <= 1'b1;
                            held_data  <= '0;
                            held_keep  <= '0;
                            state      <= ST_HEADER_BEAT0;
                        end
                        // else: stay in ST_PAYLOAD; the drain branch (below) emits
                        // the remaining held bytes with TLAST on the next cycle.
                    end
                endcase
            end else if (state == ST_PAYLOAD && (held_keep != '0)) begin
                // Drain remaining held bytes after TLAST.
                m_tdata_q  <= held_data;
                m_tkeep_q  <= held_keep;
                m_tvalid_q <= 1'b1;
                m_tlast_q  <= 1'b1;
                m_tuser_q  <= held_tuser;
                held_data  <= '0;
                held_keep  <= '0;
                held_tuser <= '0;
                state      <= ST_HEADER_BEAT0;
            end
        end
    end

endmodule
