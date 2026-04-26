// extract_exec.sv — ITCH 'E' (Order Executed, 31 B) and 'C' (Order Executed
// With Price, 36 B) extractor.  Emits book_event_t with ev_type=EV_EXEC or
// EV_EXEC_PX.
//
// AXI-S byte ordering: s_tdata is loaded little-endian, so ITCH byte N of the
// incoming message sits at buf_r[8*(N+1)-1 : 8*N] after buffering.

`ifndef EXTRACT_EXEC_SV
`define EXTRACT_EXEC_SV

`include "book_event_pkg.sv"

module extract_exec #(
    parameter int unsigned DATA_W = 64,
    parameter int unsigned TS_W   = 48
) (
    input  logic                       clk,
    input  logic                       rstn,

    input  logic [DATA_W-1:0]          s_tdata,
    input  logic [DATA_W/8-1:0]        s_tkeep,
    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic                       s_tlast,
    input  logic [TS_W-1:0]            s_tuser,

    output book_event_pkg::book_event_t m_event,
    output logic                       m_valid,
    input  logic                       m_ready
);

    import book_event_pkg::*;

    // -----------------------------------------------------------------------
    // Internal state
    // -----------------------------------------------------------------------

    // 5 beats × 8 bytes = 320-bit buffer.
    // Beat i is stored at buf_r[i*DATA_W +: DATA_W].
    // ITCH byte N sits at buf_r[8*(N+1)-1 : 8*N].
    localparam int BEATS = 5;
    localparam int BUF_W = BEATS * DATA_W;  // 320

    // Not all bytes are extracted; unused bits suppressed below.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [BUF_W-1:0]  buf_r;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [2:0]        beat_cnt;    // beats received so far (0..4)
    logic [TS_W-1:0]   ts_r;
    logic              is_exec_px;  // 0=E (EV_EXEC), 1=C (EV_EXEC_PX)
    logic              tlast_seen;  // TLAST was accepted last cycle
    logic              holding;     // output event register valid

    book_event_t       event_r;

    // s_tkeep is present in the interface for consistency but not decoded
    // (messages are fixed-length; field extraction is by byte offset).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [DATA_W/8-1:0] _unused_tkeep;
    assign _unused_tkeep = s_tkeep;
    /* verilator lint_on UNUSEDSIGNAL */

    // s_tready: accept new beats only when not holding an unacknowledged event
    assign s_tready = !holding;
    assign m_valid  = holding;
    assign m_event  = event_r;

    // -----------------------------------------------------------------------
    // Beat accumulation
    // -----------------------------------------------------------------------

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            buf_r      <= '0;
            beat_cnt   <= '0;
            ts_r       <= '0;
            is_exec_px <= 1'b0;
            tlast_seen <= 1'b0;
        end else begin
            tlast_seen <= 1'b0;  // single-cycle pulse

            if (s_tvalid && s_tready) begin
                // Store incoming beat into buffer slot
                buf_r[beat_cnt * DATA_W +: DATA_W] <= s_tdata;

                // First beat: latch metadata
                if (beat_cnt == 3'd0) begin
                    ts_r       <= s_tuser;
                    is_exec_px <= (s_tdata[7:0] == 8'h43); // 'C' = 0x43
                end

                beat_cnt <= beat_cnt + 3'd1;

                if (s_tlast) begin
                    tlast_seen <= 1'b1;
                    beat_cnt   <= '0;  // reset counter for next message
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Field extraction from buf_r (big-endian byte-reversal)
    // ITCH byte N is at buf_r[8*(N+1)-1 : 8*N]
    // -----------------------------------------------------------------------

    // stock_locate = {msg[1], msg[2]}
    logic [15:0] f_symbol_id;
    assign f_symbol_id = {buf_r[8*2-1  : 8*1], buf_r[8*3-1  : 8*2]};

    // order_id = {msg[11]..msg[18]}
    logic [63:0] f_order_id;
    assign f_order_id = {
        buf_r[8*12-1 : 8*11],
        buf_r[8*13-1 : 8*12],
        buf_r[8*14-1 : 8*13],
        buf_r[8*15-1 : 8*14],
        buf_r[8*16-1 : 8*15],
        buf_r[8*17-1 : 8*16],
        buf_r[8*18-1 : 8*17],
        buf_r[8*19-1 : 8*18]
    };

    // executed_shares = {msg[19]..msg[22]}
    logic [31:0] f_shares;
    assign f_shares = {
        buf_r[8*20-1 : 8*19],
        buf_r[8*21-1 : 8*20],
        buf_r[8*22-1 : 8*21],
        buf_r[8*23-1 : 8*22]
    };

    // price (C-only) = {msg[32]..msg[35]}
    logic [31:0] f_price_c;
    assign f_price_c = {
        buf_r[8*33-1 : 8*32],
        buf_r[8*34-1 : 8*33],
        buf_r[8*35-1 : 8*34],
        buf_r[8*36-1 : 8*35]
    };

    // -----------------------------------------------------------------------
    // Event assembly and output holding register
    // -----------------------------------------------------------------------

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            holding <= 1'b0;
            event_r <= '0;
        end else begin
            if (holding && m_ready) begin
                holding <= 1'b0;
            end

            if (tlast_seen && !holding) begin
                // buf_r is now fully settled (last beat's NB assignment resolved)
                event_r.ev_type    <= is_exec_px ? EV_EXEC_PX : EV_EXEC;
                event_r.side       <= 8'h00;
                event_r.symbol_id  <= f_symbol_id;
                event_r.price      <= is_exec_px ? f_price_c : 32'h0;
                event_r.shares     <= f_shares;
                event_r._pad       <= 32'h0;
                event_r.order_id   <= f_order_id;
                event_r.ingress_ts <= {{(64-TS_W){1'b0}}, ts_r};
                holding            <= 1'b1;
            end
        end
    end

endmodule : extract_exec

`endif // EXTRACT_EXEC_SV
