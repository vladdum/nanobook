// SPDX-License-Identifier: Apache-2.0
// msg_boundary — pipeline stage 2: slice the post-mold_strip payload into
// one ITCH message per AXI-S output frame using the 2-byte big-endian
// length prefix at the head of each message.
//
// The length prefix is consumed (NOT forwarded); the output frame contains
// only the message body bytes (type byte at output offset 0).
//
// Multi-message support: after asserting TLAST for one message, the FSM
// immediately begins parsing the next length prefix from the same input
// stream (no gap between messages in the input beat stream).
//
// Zero-length: when the parsed length is 0, frame_malformed is incremented
// and parsing continues at the next byte position (no output frame emitted).
//
// Byte ordering: AXI-S TDATA is little-endian byte-lane (byte 0 of wire
// stream lands in TDATA[7:0]). ITCH length prefix is big-endian on the wire
// so the first (high) byte is at the lower TDATA lane of the beat that
// contains it.

module msg_boundary #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                clk,
    input  logic                rstn,

    input  logic [DATA_W-1:0]   s_tdata,
    input  logic [DATA_W/8-1:0] s_tkeep,
    input  logic                s_tvalid,
    output logic                s_tready,
    input  logic                s_tlast,
    input  logic [TS_W-1:0]     s_tuser,

    output logic [DATA_W-1:0]   m_tdata,
    output logic [DATA_W/8-1:0] m_tkeep,
    output logic                m_tvalid,
    input  logic                m_tready,
    output logic                m_tlast,
    output logic [TS_W-1:0]     m_tuser,

    output logic [31:0]         frame_malformed
);
    // -----------------------------------------------------------------------
    // Local parameters
    // -----------------------------------------------------------------------
    localparam int unsigned BYTES = DATA_W / 8;  // 8

    // -----------------------------------------------------------------------
    // Input beat holding register
    // We accept one beat from upstream and hold it while we consume it
    // byte-by-byte. s_tready goes high when hold is empty.
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]   hold_data;
    logic [BYTES-1:0]    hold_keep;
    /* verilator lint_off UNUSEDSIGNAL */
    logic                hold_last;   // s_tlast of the held beat (unused for now)
    /* verilator lint_on UNUSEDSIGNAL */
    logic [TS_W-1:0]     hold_tuser;
    logic                hold_valid;  // a beat is currently held

    // byte pointer within hold_data: which byte are we about to consume (0-7)
    logic [2:0]          bptr;

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_LEN0,   // consuming length byte 0 (high byte, big-endian)
        ST_LEN1,   // consuming length byte 1 (low byte)
        ST_BODY,   // forwarding body bytes to output
        ST_DRAIN   // draining pending partial output beat after message end
    } state_e;

    state_e state;

    logic [7:0]   len_hi;      // high byte of length prefix
    logic [15:0]  body_rem;    // bytes remaining in current message body
    logic [TS_W-1:0] msg_tuser; // tuser captured at start of message

    // -----------------------------------------------------------------------
    // Output accumulation buffer
    // -----------------------------------------------------------------------
    logic [DATA_W-1:0]   obuf_data;
    logic [BYTES-1:0]    obuf_keep;
    logic [2:0]          optr;       // next write position in obuf (0-7)

    // Output registers
    logic [DATA_W-1:0]   m_tdata_q;
    logic [BYTES-1:0]    m_tkeep_q;
    logic                m_tvalid_q;
    logic                m_tlast_q;
    logic [TS_W-1:0]     m_tuser_q;

    logic [31:0]         malformed_q;

    assign m_tdata         = m_tdata_q;
    assign m_tkeep         = m_tkeep_q;
    assign m_tvalid        = m_tvalid_q;
    assign m_tlast         = m_tlast_q;
    assign m_tuser         = m_tuser_q;
    assign frame_malformed = malformed_q;

    // s_tready: accept new beat only when hold is empty AND output is not stalling us.
    // We cannot consume the hold register while m_tvalid_q=1 and m_tready=0 because
    // the FSM would overwrite m_tdata_q before downstream has consumed it.
    assign s_tready = !hold_valid && !(m_tvalid_q && !m_tready);

    // -----------------------------------------------------------------------
    // Combinational helpers
    // -----------------------------------------------------------------------

    // Current byte being consumed from hold register
    logic [7:0] cur_byte;
    assign cur_byte = hold_data[bptr*8 +: 8];

    // Number of valid bytes in held beat (derived from TKEEP).
    // For full beats (non-TLAST) tkeep = 0xFF so this = 8.
    logic [3:0] hold_valid_bytes;
    always_comb begin
        hold_valid_bytes = 4'd0;
        for (int i = 0; i < int'(BYTES); i++) begin
            if (hold_keep[i]) hold_valid_bytes = 4'(i + 1);
        end
    end

    // Whether consuming bptr exhausts the current beat.
    logic beat_exhausted;
    assign beat_exhausted = ({1'b0, bptr} + 4'd1 == hold_valid_bytes);

    // Next output buffer pointer (wraps mod 8)
    logic [2:0] next_optr;
    assign next_optr = optr + 3'd1;

    // Whether output buffer becomes full after writing to optr.
    logic obuf_full;
    assign obuf_full = (next_optr == 3'd0);  // wrapped: optr was 7

    // -----------------------------------------------------------------------
    // Main sequential logic
    // -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rstn) begin
            hold_valid  <= 1'b0;
            hold_data   <= '0;
            hold_keep   <= '0;
            hold_last   <= 1'b0;
            hold_tuser  <= '0;
            bptr        <= '0;
            state       <= ST_LEN0;
            len_hi      <= '0;
            body_rem    <= '0;
            msg_tuser   <= '0;
            obuf_data   <= '0;
            obuf_keep   <= '0;
            optr        <= '0;
            m_tdata_q   <= '0;
            m_tkeep_q   <= '0;
            m_tvalid_q  <= 1'b0;
            m_tlast_q   <= 1'b0;
            m_tuser_q   <= '0;
            malformed_q <= '0;
        end else begin
            // Deassert output only when consumed by downstream.
            if (m_tvalid_q && m_tready) begin
                m_tvalid_q <= 1'b0;
                m_tlast_q  <= 1'b0;
            end

            // -----------------------------------------------------------------
            // Accept new input beat when hold is empty AND we are not stalling.
            // (s_tready combinationally gates upstream, but we also gate here to
            // keep hold_valid consistent with the handshake.)
            // -----------------------------------------------------------------
            if (!hold_valid && s_tvalid && s_tready) begin
                hold_data  <= s_tdata;
                hold_keep  <= s_tkeep;
                hold_last  <= s_tlast;
                hold_tuser <= s_tuser;
                hold_valid <= 1'b1;
                bptr       <= '0;
            end

            // -----------------------------------------------------------------
            // ST_DRAIN: flush partial output buffer as a TLAST beat.
            // Stall if output register is still occupied (not yet consumed).
            // -----------------------------------------------------------------
            if (state == ST_DRAIN && !(m_tvalid_q && !m_tready)) begin
                m_tdata_q  <= obuf_data;
                m_tkeep_q  <= obuf_keep;
                m_tvalid_q <= 1'b1;
                m_tlast_q  <= 1'b1;
                m_tuser_q  <= msg_tuser;
                obuf_data  <= '0;
                obuf_keep  <= '0;
                optr       <= '0;
                state      <= ST_LEN0;
                // If we just loaded a new beat this cycle, keep hold_valid as set.
                // (hold was empty before; the load-path above may have set it.)
            end else if (hold_valid && !(m_tvalid_q && !m_tready)) begin
                // -----------------------------------------------------------------
                // Byte-pump FSM: consume one byte per clock from hold register.
                // -----------------------------------------------------------------
                if (beat_exhausted) begin
                    hold_valid <= 1'b0;
                end else begin
                    bptr <= bptr + 3'd1;
                end

                case (state)
                    // -----------------------------------------------------
                    ST_LEN0: begin
                        len_hi    <= cur_byte;
                        msg_tuser <= hold_tuser;  // capture TUSER at msg start
                        state     <= ST_LEN1;
                    end
                    // -----------------------------------------------------
                    ST_LEN1: begin
                        begin
                            logic [15:0] msg_len;
                            msg_len = {len_hi, cur_byte};
                            if (msg_len == 16'd0) begin
                                malformed_q <= malformed_q + 32'd1;
                                state       <= ST_LEN0;
                            end else begin
                                body_rem <= msg_len;
                                state    <= ST_BODY;
                            end
                        end
                    end
                    // -----------------------------------------------------
                    ST_BODY: begin
                        // Write current byte into output accumulation buffer.
                        obuf_data[optr*8 +: 8] <= cur_byte;
                        obuf_keep[optr]        <= 1'b1;

                        if (body_rem == 16'd1) begin
                            // Last byte of this message.
                            if (obuf_full) begin
                                // Output buffer exactly full — emit full beat with TLAST.
                                // The byte we just wrote is in obuf_data/obuf_keep already
                                // (assignments above take effect next cycle in RTL, but
                                // since we're building the emit value here, include it):
                                m_tdata_q              <= obuf_data;
                                m_tdata_q[optr*8 +: 8] <= cur_byte;
                                m_tkeep_q              <= obuf_keep;
                                m_tkeep_q[optr]        <= 1'b1;
                                m_tvalid_q             <= 1'b1;
                                m_tlast_q              <= 1'b1;
                                m_tuser_q              <= msg_tuser;
                                obuf_data              <= '0;
                                obuf_keep              <= '0;
                                optr                   <= '0;
                                state                  <= ST_LEN0;
                            end else begin
                                // Partial output buffer — drain next cycle.
                                optr  <= next_optr;
                                state <= ST_DRAIN;
                            end
                            body_rem <= 16'd0;
                        end else begin
                            // More body bytes remain.
                            body_rem <= body_rem - 16'd1;
                            if (obuf_full) begin
                                // Output buffer full — emit non-last beat.
                                m_tdata_q              <= obuf_data;
                                m_tdata_q[optr*8 +: 8] <= cur_byte;
                                m_tkeep_q              <= obuf_keep;
                                m_tkeep_q[optr]        <= 1'b1;
                                m_tvalid_q             <= 1'b1;
                                m_tlast_q              <= 1'b0;
                                m_tuser_q              <= msg_tuser;
                                obuf_data              <= '0;
                                obuf_keep              <= '0;
                                optr                   <= '0;
                                msg_tuser              <= '0;  // TUSER only on first beat
                            end else begin
                                optr <= next_optr;
                            end
                        end
                    end
                    // -----------------------------------------------------
                    default: ;
                endcase
            end
        end
    end

endmodule
