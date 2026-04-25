#include <refbook/sliding_window.h>

#include <refbook/price_ladder.h>

namespace refbook {

SlidingWindow::SlidingWindow(uint32_t initial_midprice)
    : midprice_(initial_midprice),
      origin_(initial_midprice >= kWindowHalfWidth
                  ? initial_midprice - kWindowHalfWidth
                  : 0) {}

std::optional<uint32_t> SlidingWindow::price_to_tick(uint32_t price) const {
  if (price < origin_) return std::nullopt;
  uint32_t offset = price - origin_;
  if (offset >= 2 * kWindowHalfWidth) return std::nullopt;
  return offset;
}

uint32_t SlidingWindow::tick_to_price(uint32_t tick) const {
  return origin_ + tick;
}

void SlidingWindow::update_midprice(uint32_t price) {
  // midprice += (price - midprice) >> kEmaShift, guarding the sign.
  // NOTE: midprice may drift relative to origin between rebases. Window
  // re-centering is event-driven (incoming-price-out-of-window), not
  // midprice-driven. RTL in M05+ MUST match this behavior.
  int64_t diff = static_cast<int64_t>(price) - static_cast<int64_t>(midprice_);
  midprice_ = static_cast<uint32_t>(
      static_cast<int64_t>(midprice_) + (diff >> kEmaShift));
}

bool SlidingWindow::needs_rebase(uint32_t price) const {
  return !price_to_tick(price).has_value();
}

void SlidingWindow::rebase(PriceLadder& ladder, uint32_t price) {
  // Drop-on-rebase: discard the entire ladder and re-center the window on the
  // triggering price. Orders remain in the OrderPool but are unreachable from
  // the new ladder; real RTL (M05+) will escalate stale orders to host
  // slow-path. RTL MUST match this drop semantics for correctness against the
  // refbook golden model.
  ladder = PriceLadder{};
  origin_ = (price >= kWindowHalfWidth) ? price - kWindowHalfWidth : 0;
  ++rebases_;
  // Update midprice after origin shift so the same event cannot re-trigger.
  midprice_ = price;
}

}  // namespace refbook
