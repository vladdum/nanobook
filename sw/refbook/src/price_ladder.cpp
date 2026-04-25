#include <refbook/price_ladder.h>

#include <refbook/order_pool.h>

#include <cassert>

namespace refbook {

PriceLadder::PriceLadder() = default;

void PriceLadder::set_bit(uint8_t side, uint32_t tick) {
  bitmap_[side][tick / 64] |= (uint64_t{1} << (tick % 64));
}

void PriceLadder::clear_bit(uint8_t side, uint32_t tick) {
  bitmap_[side][tick / 64] &= ~(uint64_t{1} << (tick % 64));
}

void PriceLadder::add(uint8_t side, uint32_t tick, uint32_t slot, uint64_t shares,
                      OrderPool& pool) {
  assert(tick < kLadderTicks);
  auto& lvl = levels_[side][tick];
  if (lvl.order_count == 0) {
    lvl.head_slot = slot;
    lvl.tail_slot = slot;
    pool.at(slot).prev_slot = kNullSlot;
    pool.at(slot).next_slot = kNullSlot;
    set_bit(side, tick);
  } else {
    pool.at(slot).prev_slot          = lvl.tail_slot;
    pool.at(slot).next_slot          = kNullSlot;
    pool.at(lvl.tail_slot).next_slot = slot;
    lvl.tail_slot                    = slot;
  }
  lvl.agg_size    += shares;
  lvl.order_count += 1;
  auto fb = find_best(side);
  cached_best_[side] = (fb == UINT32_MAX) ? std::optional<uint32_t>{} : std::optional<uint32_t>{fb};
}

void PriceLadder::remove(uint8_t side, uint32_t tick, uint32_t slot, uint64_t shares,
                         OrderPool& pool) {
  assert(tick < kLadderTicks);
  auto& lvl = levels_[side][tick];
  auto& rec = pool.at(slot);
  if (rec.prev_slot != kNullSlot) pool.at(rec.prev_slot).next_slot = rec.next_slot;
  if (rec.next_slot != kNullSlot) pool.at(rec.next_slot).prev_slot = rec.prev_slot;
  if (lvl.head_slot == slot) lvl.head_slot = rec.next_slot;
  if (lvl.tail_slot == slot) lvl.tail_slot = rec.prev_slot;
  lvl.agg_size    -= shares;
  lvl.order_count -= 1;
  if (lvl.order_count == 0) {
    clear_bit(side, tick);
  }
  auto fb = find_best(side);
  cached_best_[side] = (fb == UINT32_MAX) ? std::optional<uint32_t>{} : std::optional<uint32_t>{fb};
}

bool PriceLadder::decrement_shares(uint8_t side, uint32_t tick, uint64_t delta) {
  auto& lvl = levels_[side][tick];
  assert(lvl.agg_size >= delta);
  lvl.agg_size -= delta;
  return lvl.agg_size == 0;
}

std::optional<uint32_t> PriceLadder::best(uint8_t side) const {
  return cached_best_[side];
}

const TickLevel& PriceLadder::level(uint8_t side, uint32_t tick) const {
  return levels_[side][tick];
}

uint32_t PriceLadder::find_best(uint8_t side) const {
  // Bid: highest set bit. Ask: lowest set bit.
  if (side == 0) {
    for (int w = kBitmapWords - 1; w >= 0; --w) {
      auto word = bitmap_[side][w];
      if (word) {
        int hbit = 63 - __builtin_clzll(word);
        return static_cast<uint32_t>(w) * 64u + static_cast<uint32_t>(hbit);
      }
    }
  } else {
    for (uint32_t w = 0; w < kBitmapWords; ++w) {
      auto word = bitmap_[side][w];
      if (word) {
        int lbit = __builtin_ctzll(word);
        return w * 64u + static_cast<uint32_t>(lbit);
      }
    }
  }
  return UINT32_MAX;  // Encoded as "no best" via cached_best_ = nullopt above.
}

}  // namespace refbook
