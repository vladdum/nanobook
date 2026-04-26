// AUTO-GENERATED FROM sw/refbook/include/refbook/book_event.h
// DO NOT EDIT BY HAND. Run hw/ip/itch_decoder/scripts/gen_book_event_pkg.py
// to regenerate. CI asserts `git diff --exit-code` against this file.

`ifndef BOOK_EVENT_PKG_SV
`define BOOK_EVENT_PKG_SV

package book_event_pkg;

  // event_type_e — mirrors enum class EventType : uint8_t
  typedef enum logic [7:0] {
    EV_ADD     = 8'h00,
    EV_CANCEL  = 8'h01,
    EV_DELETE  = 8'h02,
    EV_EXEC    = 8'h03,
    EV_EXEC_PX = 8'h04
  } event_type_e;

  // book_event_t — mirrors struct BookEvent
  // total 32 bytes (256 bits) — mirrors C++ layout
  typedef struct packed {
    logic [7:0]  ev_type;
    logic [7:0]  side;
    logic [15:0] symbol_id;
    logic [31:0] price;
    logic [31:0] shares;
    logic [31:0] _pad;
    logic [63:0] order_id;
    logic [63:0] ingress_ts;
  } book_event_t;

endpackage : book_event_pkg

`endif // BOOK_EVENT_PKG_SV
