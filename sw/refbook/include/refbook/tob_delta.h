// SPDX-License-Identifier: Apache-2.0
// Nanobook reference book — TOB delta format (spec §5.2).
// FROZEN at M02. Consumers: M4–M12 (refbook, analyzer, RTL packer).
// Any change requires a spec-amendment PR first.
#pragma once

#include <cstdint>

namespace refbook {

enum class TobReason : uint8_t {
  Add    = 0,
  Cancel = 1,
  Delete = 2,
  Exec   = 3,
  ExecPx = 4,
};

#pragma pack(push, 1)
struct TobDelta {
  uint64_t ingress_ts;      // 0x00 — from BookEvent.ingress_ts
  uint64_t emit_ts;         // 0x08 — verbatim copy of ingress_ts in refbook
  uint16_t symbol_id;       // 0x10
  uint8_t  side;            // 0x12 — 0 = bid, 1 = ask
  uint8_t  reason;          // 0x13 — TobReason
  uint32_t new_best_price;  // 0x14
  uint32_t new_best_size;   // 0x18
  uint32_t flags;           // 0x1C — bit 0 = valid; bit 1 = side_empty
};
#pragma pack(pop)

static_assert(sizeof(TobDelta) == 32, "TobDelta must be exactly 32 bytes");
static_assert(alignof(TobDelta) == 1, "TobDelta must be byte-aligned (packed)");

}  // namespace refbook
