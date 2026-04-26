// extract_replace.sv — ITCH 'U' (Order Replace, 35 B) field extractor
// Emits TWO book_event_t events per input message:
//   1. EV_DELETE for orig_order_id
//   2. EV_ADD    for new_order_id (with new shares/price)

`ifndef EXTRACT_REPLACE_SV
`define EXTRACT_REPLACE_SV

`include "book_event_pkg.sv"

module extract_replace #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                       clk,
    input  logic                       rstn,

    // Input AXI-S: ITCH 'U' message body, post type-dispatch
    input  logic [DATA_W-1:0]          s_tdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [DATA_W/8-1:0]        s_tkeep,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic                       s_tlast,
    input  logic [TS_W-1:0]            s_tuser,

    // Output: assembled book_event_t (two events per input message)
    output book_event_pkg::book_event_t m_event,
    output logic                       m_valid,
    input  logic                       m_ready,

    // Increments by 1 each time a U input produces a (DELETE, ADD) pair
    output logic [31:0]                replace_split
);
    import book_event_pkg::*;

    // ----------------------------------------------------------------
    // State machine
    // ----------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE         = 2'd0,
        ST_BUFFER       = 2'd1,
        ST_EMIT_DELETE  = 2'd2,
        ST_EMIT_ADD     = 2'd3
    } state_t;

    state_t state_r;

    // 320-bit buffer holds up to 5 beats (40 bytes for 'U' at 35 B).
    // Several byte ranges are intentionally ignored (tracking bytes, etc.).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [319:0] buf_r;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [2:0]   beat_idx;
    logic [TS_W-1:0] ts_r;
    logic [31:0]  replace_split_r;

    // ----------------------------------------------------------------
    // s_tready: accept input in IDLE and BUFFER states
    // ----------------------------------------------------------------
    assign s_tready = (state_r == ST_IDLE) || (state_r == ST_BUFFER);

    // ----------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r         <= ST_IDLE;
            buf_r           <= '0;
            beat_idx        <= '0;
            ts_r            <= '0;
            replace_split_r <= '0;
        end else begin
            unique case (state_r)

                ST_IDLE: begin
                    if (s_tvalid) begin
                        // Capture first beat
                        buf_r[63:0] <= s_tdata;
                        ts_r        <= s_tuser;
                        beat_idx    <= 3'd1;
                        if (s_tlast) begin
                            // Single-beat message (shouldn't happen for 35 B, but be safe)
                            replace_split_r <= replace_split_r + 32'd1;
                            state_r         <= ST_EMIT_DELETE;
                            beat_idx        <= '0;
                        end else begin
                            state_r  <= ST_BUFFER;
                        end
                    end
                end

                ST_BUFFER: begin
                    if (s_tvalid) begin
                        case (beat_idx)
                            3'd1: buf_r[127: 64] <= s_tdata;
                            3'd2: buf_r[191:128] <= s_tdata;
                            3'd3: buf_r[255:192] <= s_tdata;
                            3'd4: buf_r[319:256] <= s_tdata;
                            default: ; // ignore extra beats
                        endcase

                        if (s_tlast) begin
                            replace_split_r <= replace_split_r + 32'd1;
                            state_r         <= ST_EMIT_DELETE;
                            beat_idx        <= '0;
                        end else begin
                            beat_idx <= beat_idx + 3'd1;
                        end
                    end
                end

                ST_EMIT_DELETE: begin
                    if (m_ready) begin
                        state_r <= ST_EMIT_ADD;
                    end
                end

                ST_EMIT_ADD: begin
                    if (m_ready) begin
                        state_r  <= ST_IDLE;
                        buf_r    <= '0;
                        beat_idx <= '0;
                    end
                end

                default: state_r <= ST_IDLE;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // Field extraction (combinational from buffer)
    // Byte N of message is at buf_r[8*N+7 : 8*N]
    //
    // 'U' layout:
    //   byte  0: type ('U')
    //   bytes 1-2:  stock_locate (uint16 big-endian)
    //   bytes 3-4:  tracking_number (ignored)
    //   bytes 5-10: timestamp (uint48 big-endian)   — captured via s_tuser
    //   bytes 11-18: orig_order_id (uint64 big-endian)
    //   bytes 19-26: new_order_id  (uint64 big-endian)
    //   bytes 27-30: shares        (uint32 big-endian)
    //   bytes 31-34: price         (uint32 big-endian)
    // ----------------------------------------------------------------

    // symbol_id: bytes 1-2 big-endian
    logic [15:0] w_symbol_id;
    assign w_symbol_id = {buf_r[15:8], buf_r[23:16]};

    // orig_order_id: bytes 11-18 big-endian
    logic [63:0] w_orig_order_id;
    assign w_orig_order_id = {
        buf_r[ 95: 88],  // byte 11 (MSB)
        buf_r[103: 96],  // byte 12
        buf_r[111:104],  // byte 13
        buf_r[119:112],  // byte 14
        buf_r[127:120],  // byte 15
        buf_r[135:128],  // byte 16
        buf_r[143:136],  // byte 17
        buf_r[151:144]   // byte 18 (LSB)
    };

    // new_order_id: bytes 19-26 big-endian
    logic [63:0] w_new_order_id;
    assign w_new_order_id = {
        buf_r[159:152],  // byte 19 (MSB)
        buf_r[167:160],  // byte 20
        buf_r[175:168],  // byte 21
        buf_r[183:176],  // byte 22
        buf_r[191:184],  // byte 23
        buf_r[199:192],  // byte 24
        buf_r[207:200],  // byte 25
        buf_r[215:208]   // byte 26 (LSB)
    };

    // shares: bytes 27-30 big-endian
    logic [31:0] w_shares;
    assign w_shares = {
        buf_r[223:216],  // byte 27 (MSB)
        buf_r[231:224],  // byte 28
        buf_r[239:232],  // byte 29
        buf_r[247:240]   // byte 30 (LSB)
    };

    // price: bytes 31-34 big-endian
    logic [31:0] w_price;
    assign w_price = {
        buf_r[255:248],  // byte 31 (MSB)
        buf_r[263:256],  // byte 32
        buf_r[271:264],  // byte 33
        buf_r[279:272]   // byte 34 (LSB)
    };

    // ----------------------------------------------------------------
    // Output mux: DELETE in ST_EMIT_DELETE, ADD in ST_EMIT_ADD
    // ----------------------------------------------------------------
    always_comb begin
        m_event         = '0;
        m_event._pad    = 32'h0;
        m_event.symbol_id  = w_symbol_id;
        m_event.ingress_ts = {{(64-TS_W){1'b0}}, ts_r};

        unique case (state_r)
            ST_EMIT_DELETE: begin
                m_event.ev_type  = EV_DELETE;
                m_event.side     = 8'h00;
                m_event.price    = 32'h0;
                m_event.shares   = 32'h0;
                m_event.order_id = w_orig_order_id;
            end
            ST_EMIT_ADD: begin
                m_event.ev_type  = EV_ADD;
                m_event.side     = 8'h00;
                m_event.price    = w_price;
                m_event.shares   = w_shares;
                m_event.order_id = w_new_order_id;
            end
            default: begin
                m_event.ev_type  = EV_DELETE;
                m_event.side     = 8'h00;
                m_event.price    = 32'h0;
                m_event.shares   = 32'h0;
                m_event.order_id = 64'h0;
            end
        endcase
    end

    assign m_valid       = (state_r == ST_EMIT_DELETE) || (state_r == ST_EMIT_ADD);
    assign replace_split = replace_split_r;

endmodule : extract_replace

`endif // EXTRACT_REPLACE_SV
