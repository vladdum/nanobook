// SPDX-License-Identifier: Apache-2.0
// Slab-allocated pool of order records with intrusive doubly-linked list indices.
// Behavioral component — internal state not observable at TOB boundary.
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

namespace refbook {

// Sentinel for "no neighbor" in the intrusive list.
inline constexpr uint32_t kNullSlot = std::numeric_limits<uint32_t>::max();

// 32 bytes — field order mirrors the RTL record for debuggability only.
struct OrderRecord {
  uint64_t order_id;   // 0x00
  uint32_t shares;     // 0x08
  uint32_t price;      // 0x0C
  uint32_t prev_slot;  // 0x10
  uint32_t next_slot;  // 0x14
  uint16_t symbol_id;  // 0x18
  uint8_t  side;       // 0x1A — 0 = bid, 1 = ask
  uint8_t  flags;      // 0x1B — bit 0 = active
  uint32_t _pad;       // 0x1C — reserved
};
static_assert(sizeof(OrderRecord) == 32, "OrderRecord must be exactly 32 bytes");

class OrderPool {
 public:
  explicit OrderPool(std::size_t capacity);

  // Returns a slot index. Throws std::runtime_error if pool is exhausted.
  uint32_t allocate();

  // Marks a slot free; O(1).
  void release(uint32_t slot);

  // Accessors.
  OrderRecord&       at(uint32_t slot);
  const OrderRecord& at(uint32_t slot) const;

  // Introspection (property-test hooks).
  std::size_t capacity()   const { return records_.size(); }
  std::size_t active_count() const { return active_; }

 private:
  std::vector<OrderRecord> records_;
  uint32_t                 free_head_ = kNullSlot;
  std::size_t              active_    = 0;
};

}  // namespace refbook
