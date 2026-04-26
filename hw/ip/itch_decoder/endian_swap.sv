// endian_swap.sv — reorder a book_event_t 256-bit word to match BookEvent.pack() layout.
//
// Input (s_event): SV-packed book_event_t natural layout (field MSB at highest bit):
//   [255:248] ev_type   (8-bit)
//   [247:240] side      (8-bit)
//   [239:224] symbol_id (16-bit, MSB at bit 239)
//   [223:192] price     (32-bit, MSB at bit 223)
//   [191:160] shares    (32-bit, MSB at bit 191)
//   [159:128] _pad      (32-bit)
//   [127:64]  order_id  (64-bit, MSB at bit 127)
//   [63:0]    ingress_ts(64-bit, MSB at bit 63)
//
// Output (m_event): BookEvent.pack() byte layout (<BBHII4xQQ little-endian):
//   TDATA[7:0]    byte 0 : ev_type
//   TDATA[15:8]   byte 1 : side
//   TDATA[31:16]  bytes2-3: symbol_id LE (LSB at byte 2)
//   TDATA[63:32]  bytes4-7: price LE
//   TDATA[95:64]  bytes8-11: shares LE
//   TDATA[127:96] bytes12-15: _pad LE
//   TDATA[191:128] bytes16-23: order_id LE
//   TDATA[255:192] bytes24-31: ingress_ts LE
//
// For each multi-byte field, the SV LSB maps to the lowest TDATA bit in its target
// range (no within-field byte reversal — SV packs LSB at lowest bit already).

module endian_swap #(
    parameter int unsigned EVENT_W = 256
) (
    input  logic                clk,
    input  logic                rstn,

    // Input: book_event_t in SV-packed natural layout (extractor convention)
    input  logic [EVENT_W-1:0]  s_event,
    input  logic                s_valid,
    output logic                s_ready,

    // Output: 256-bit AXI-S-style word in BookEvent.pack() byte order
    output logic [EVENT_W-1:0]  m_event,
    output logic                m_valid,
    input  logic                m_ready
);

    // Field remapping: place each field at its BookEvent.pack() TDATA position.
    // SV-packed layout: field MSB at highest bit; LSB byte at lowest bit within field.
    // Target: little-endian byte lanes so LSB byte of each field sits at lowest target bit.
    logic [EVENT_W-1:0] remapped;
    always_comb begin
        remapped = '0;
        // ev_type  [255:248] -> TDATA[7:0]
        remapped[7:0]     = s_event[255:248];
        // side     [247:240] -> TDATA[15:8]
        remapped[15:8]    = s_event[247:240];
        // symbol_id[239:224] -> TDATA[31:16]  (LSB=s_event[231:224] -> TDATA[23:16])
        remapped[31:16]   = s_event[239:224];
        // price    [223:192] -> TDATA[63:32]
        remapped[63:32]   = s_event[223:192];
        // shares   [191:160] -> TDATA[95:64]
        remapped[95:64]   = s_event[191:160];
        // _pad     [159:128] -> TDATA[127:96]
        remapped[127:96]  = s_event[159:128];
        // order_id [127:64]  -> TDATA[191:128]
        remapped[191:128] = s_event[127:64];
        // ingress_ts[63:0]   -> TDATA[255:192]
        remapped[255:192] = s_event[63:0];
    end

    // Single-beat registered passthrough with handshake.
    logic [EVENT_W-1:0] event_q;
    logic               valid_q;
    assign m_event = event_q;
    assign m_valid = valid_q;
    assign s_ready = !valid_q || m_ready;

    always_ff @(posedge clk) begin
        if (!rstn) begin
            event_q <= '0;
            valid_q <= 1'b0;
        end else begin
            if (m_valid && m_ready) valid_q <= 1'b0;
            if (s_valid && s_ready) begin
                event_q <= remapped;
                valid_q <= 1'b1;
            end
        end
    end

endmodule
