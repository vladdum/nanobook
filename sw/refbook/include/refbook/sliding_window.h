// SPDX-License-Identifier: Apache-2.0
// Per-symbol sliding window of ±2048 ticks around midprice.
// Structural component — rebase trigger and EMA match RTL (M05+).
//
// FROZEN CONTRACT (M02): the rebase algorithm below is authoritative.
//   - Midprice is an EMA with α = 1/16 over prices seen on ADD events.
//   - Rebase triggers when an incoming price is outside the window
//     [origin, origin + 4096) — equivalently, ladder ticks [0, 4095].
//   - On rebase: discard all active ticks (drop-on-rebase, not translate);
//     new origin = trigger_price - 2048; new midprice = trigger_price so the
//     same event cannot re-trigger. Orders in dropped levels remain in the
//     OrderPool but are unreachable; M05+ RTL escalates them via slow-path.
#pragma once

#include <cstdint>
#include <optional>

namespace refbook {

inline constexpr uint32_t kWindowHalfWidth     = 2048;  // ±2048 ticks
inline constexpr uint32_t kEmaShift            = 4;     // α = 1/16

class PriceLadder;

class SlidingWindow {
 public:
  explicit SlidingWindow(uint32_t initial_midprice = 0);

  // Returns the tick offset for the given price, or nullopt if outside the window.
  std::optional<uint32_t> price_to_tick(uint32_t price) const;

  // Translates a tick offset back to an absolute price.
  uint32_t tick_to_price(uint32_t tick) const;

  // EMA update; call after each ADD event.
  void update_midprice(uint32_t price);

  // True if `price` is outside the window and requires a rebase.
  bool needs_rebase(uint32_t price) const;

  // Execute the rebase. `ladder` is translated in-place.
  void rebase(PriceLadder& ladder, uint32_t price);

  uint32_t midprice() const { return midprice_; }
  uint32_t origin()   const { return origin_;   }
  uint64_t rebase_count() const { return rebases_; }

 private:
  uint32_t midprice_;   // EMA of observed ADD prices
  uint32_t origin_;     // Window left edge; tick=0 corresponds to price=origin_
  uint64_t rebases_ = 0;
};

}  // namespace refbook
