// event_pack.sv — registered AXI-S output stage for itch_decoder.
//
// Takes the byte-remapped 256-bit event word from endian_swap and emits it
// as the decoder's final AXI-S output. One event per beat; TLAST tied high.

module event_pack #(
    parameter int unsigned DATA_W = 256
) (
    input  logic                clk,
    input  logic                rstn,

    // Input: byte-swapped event word from endian_swap
    input  logic [DATA_W-1:0]   s_event,
    input  logic                s_valid,
    output logic                s_ready,

    // Output: AXI-S beat (256-bit)
    output logic [DATA_W-1:0]   m_tdata,
    output logic                m_tvalid,
    input  logic                m_tready,
    output logic                m_tlast
);

    logic [DATA_W-1:0] event_q;
    logic              valid_q;

    assign m_tdata  = event_q;
    assign m_tvalid = valid_q;
    assign m_tlast  = valid_q;
    assign s_ready  = !valid_q || m_tready;

    always_ff @(posedge clk) begin
        if (!rstn) begin
            event_q <= '0;
            valid_q <= 1'b0;
        end else begin
            if (m_tvalid && m_tready) valid_q <= 1'b0;
            if (s_valid && s_ready) begin
                event_q <= s_event;
                valid_q <= 1'b1;
            end
        end
    end

endmodule
