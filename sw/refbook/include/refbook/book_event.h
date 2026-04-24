// SPDX-License-Identifier: Apache-2.0
// Nanobook reference book — normalized book event (spec §3.4).
// The M03 RTL package (hw/ip/itch_decoder/book_event_pkg.sv) must
// mirror this layout at its M3 freeze.
#pragma once

#include <cstdint>

namespace refbook {

enum class EventType : uint8_t {
  Add    = 0,  // ITCH A or F
  Cancel = 1,  // ITCH X (partial cancel — shares decrement only)
  Delete = 2,  // ITCH D
  Exec   = 3,  // ITCH E (exec at display price)
  ExecPx = 4,  // ITCH C (exec at non-display price)
};

struct BookEvent {
  uint8_t  type;          // 0x00 — EventType (4 low bits used; upper bits reserved = 0)
  uint8_t  side;          // 0x01 — 0 = bid, 1 = ask; valid only for Add
  uint16_t symbol_id;     // 0x02 — stock_locate from ITCH
  uint32_t price;         // 0x04 — u32 fixed-point, 4 decimal digits
  uint32_t shares;        // 0x08 — for Cancel/Exec/ExecPx, the delta; for Add, total
  uint32_t _pad;          // 0x0C — reserved = 0
  uint64_t order_id;      // 0x10
  uint64_t ingress_ts;    // 0x18 — 48 bits used, upper 16 bits reserved = 0
};

static_assert(sizeof(BookEvent) == 32, "BookEvent must be exactly 32 bytes");

}  // namespace refbook
