// extract_add.sv — ITCH 'A' and 'F' field extractor
// Absorbs up to 5 beats (40 bytes, covering 'F' at 40 B), assembles book_event_t.

`ifndef EXTRACT_ADD_SV
`define EXTRACT_ADD_SV

`include "book_event_pkg.sv"

module extract_add #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                       clk,
    input  logic                       rstn,

    // Input AXI-S: ITCH 'A' or 'F' message body, post type-dispatch
    input  logic [DATA_W-1:0]          s_tdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [DATA_W/8-1:0]        s_tkeep,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic                       s_tlast,
    input  logic [TS_W-1:0]            s_tuser,

    // Output: assembled book_event_t (one beat per input message)
    output book_event_pkg::book_event_t m_event,
    output logic                       m_valid,
    input  logic                       m_ready
);
    import book_event_pkg::*;

    // 320-bit buffer holds up to 5 beats (40 bytes for 'F').
    // Several ranges are intentionally ignored: byte 0 (type), bytes 3-10
    // (tracking + most of timestamp), bytes 24-31 (stock symbol), bytes 36-39
    // (MPID in 'F'). Suppress the resulting unused-bits warning.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [319:0] buf_r;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [2:0]   beat_idx;
    logic         holding_event;
    logic [TS_W-1:0] ts_r;

    // Backpressure: don't accept new beats while holding an event
    assign s_tready = !holding_event;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            buf_r         <= '0;
            beat_idx      <= '0;
            holding_event <= 1'b0;
            ts_r          <= '0;
        end else begin
            // Consume event when downstream accepts
            if (holding_event && m_ready) begin
                holding_event <= 1'b0;
                beat_idx      <= '0;
                buf_r         <= '0;
            end

            // Accept incoming beats when not holding
            if (s_tvalid && s_tready) begin
                // Write beat into buffer slice
                case (beat_idx)
                    3'd0: buf_r[ 63:  0] <= s_tdata;
                    3'd1: buf_r[127: 64] <= s_tdata;
                    3'd2: buf_r[191:128] <= s_tdata;
                    3'd3: buf_r[255:192] <= s_tdata;
                    3'd4: buf_r[319:256] <= s_tdata;
                    default: ; // ignore extra beats (shouldn't happen)
                endcase

                // Capture timestamp from first beat
                if (beat_idx == 3'd0) begin
                    ts_r <= s_tuser;
                end

                if (s_tlast) begin
                    // Freeze and signal event ready
                    holding_event <= 1'b1;
                    beat_idx      <= '0;
                end else begin
                    beat_idx <= beat_idx + 3'd1;
                end
            end
        end
    end

    // Field extraction from buffer (combinational, valid when holding_event)
    // Byte N of message is at buf_r[8*N+7 : 8*N].
    //
    // symbol_id (bytes 1-2, big-endian):
    //   MSB = byte 1 = buf_r[15:8], LSB = byte 2 = buf_r[23:16]
    logic [15:0] w_symbol_id;
    assign w_symbol_id = {buf_r[15:8], buf_r[23:16]};

    // order_id (bytes 11-18, big-endian, 8 bytes):
    //   byte 11 = buf_r[95:88] ... byte 18 = buf_r[151:144]
    logic [63:0] w_order_id;
    assign w_order_id = {
        buf_r[ 95: 88],  // byte 11 (MSB)
        buf_r[103: 96],  // byte 12
        buf_r[111:104],  // byte 13
        buf_r[119:112],  // byte 14
        buf_r[127:120],  // byte 15
        buf_r[135:128],  // byte 16
        buf_r[143:136],  // byte 17
        buf_r[151:144]   // byte 18 (LSB)
    };

    // side (byte 19): 0 if 'B' (0x42), else 1
    logic [7:0] w_side;
    assign w_side = (buf_r[159:152] == 8'h42) ? 8'h00 : 8'h01;

    // shares (bytes 20-23, big-endian):
    logic [31:0] w_shares;
    assign w_shares = {
        buf_r[167:160],  // byte 20 (MSB)
        buf_r[175:168],  // byte 21
        buf_r[183:176],  // byte 22
        buf_r[191:184]   // byte 23 (LSB)
    };

    // price (bytes 32-35, big-endian):
    //   byte 32 = buf_r[263:256] ... byte 35 = buf_r[295:288]
    logic [31:0] w_price;
    assign w_price = {
        buf_r[263:256],  // byte 32 (MSB)
        buf_r[271:264],  // byte 33
        buf_r[279:272],  // byte 34
        buf_r[287:280]   // byte 35 (LSB)
    };

    // Assemble book_event_t output
    assign m_event.ev_type   = EV_ADD;
    assign m_event.side      = w_side;
    assign m_event.symbol_id = w_symbol_id;
    assign m_event.price     = w_price;
    assign m_event.shares    = w_shares;
    assign m_event._pad      = 32'h0;
    assign m_event.order_id  = w_order_id;
    assign m_event.ingress_ts = {{(64-TS_W){1'b0}}, ts_r};

    assign m_valid = holding_event;

endmodule : extract_add

`endif // EXTRACT_ADD_SV
