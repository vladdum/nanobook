// SPDX-License-Identifier: Apache-2.0
// Per-symbol, per-side ring of 4K tick-levels + 4K-bit bitmap + cached best.
// Structural component — state shape matches RTL; divergence is observable at TOB.
// Spec §4.1, §4.2, §4.5.
#pragma once

#include <refbook/order_pool.h>   // kNullSlot, OrderPool

#include <array>
#include <cstdint>
#include <optional>

namespace refbook {

inline constexpr uint32_t kLadderTicks    = 4096;      // ±2048 around midprice
inline constexpr uint32_t kBitmapWords    = 64;        // 4096 / 64
inline constexpr uint32_t kSidesPerSymbol = 2;         // bid (0), ask (1)

struct TickLevel {
  uint32_t head_slot   = kNullSlot;
  uint32_t tail_slot   = kNullSlot;
  uint64_t agg_size    = 0;
  uint32_t order_count = 0;
};
static_assert(sizeof(TickLevel) == 24, "TickLevel size pinned (RTL ladder slot mirror)");

class PriceLadder {
 public:
  PriceLadder();

  // Link / unlink an order at (side, tick_offset). Caller guarantees 0 <= tick < 4096.
  void add(uint8_t side, uint32_t tick, uint32_t slot, uint64_t shares, OrderPool& pool);
  void remove(uint8_t side, uint32_t tick, uint32_t slot, uint64_t shares, OrderPool& pool);

  // Decrement shares at (side, tick) for EXEC/CANCEL_PARTIAL.
  // Returns true if the level is now empty (caller should then invoke remove()).
  bool decrement_shares(uint8_t side, uint32_t tick, uint64_t delta);

  // Best-tick accessor. nullopt if the side is empty.
  std::optional<uint32_t> best(uint8_t side) const;

  // Read-only access to a level (for property tests).
  const TickLevel& level(uint8_t side, uint32_t tick) const;

 private:
  uint32_t find_best(uint8_t side) const;     // CLZ over bitmap
  void     set_bit(uint8_t side, uint32_t tick);
  void     clear_bit(uint8_t side, uint32_t tick);

  // [side][tick]
  std::array<std::array<TickLevel, kLadderTicks>, kSidesPerSymbol> levels_{};
  std::array<std::array<uint64_t, kBitmapWords>,  kSidesPerSymbol> bitmap_{};
  std::array<std::optional<uint32_t>,             kSidesPerSymbol> cached_best_{};
};

}  // namespace refbook
