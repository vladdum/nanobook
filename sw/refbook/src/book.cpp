#include <refbook/book.h>

#include <algorithm>
#include <cstring>
#include <stdexcept>

namespace refbook {

Book::Book(uint16_t n_symbols, std::size_t pool_capacity, uint32_t initial_midprice)
    : n_symbols_(n_symbols),
      pool_(pool_capacity),
      symbols_(n_symbols) {
  for (auto& s : symbols_) {
    s.window = SlidingWindow{initial_midprice};
  }
}

void Book::reset() {
  pool_   = OrderPool{pool_.capacity()};
  id_map_.clear();
  symbols_.assign(n_symbols_, SymbolState{});
  stats_ = {};
}

std::vector<TobDelta> Book::snapshot() const {
  std::vector<TobDelta> out;
  out.reserve(n_symbols_ * 2);
  for (uint16_t s = 0; s < n_symbols_; ++s) {
    for (uint8_t side = 0; side < 2; ++side) {
      TobDelta d{};
      d.symbol_id = s;
      d.side      = side;
      if (auto best = symbols_[s].ladder.best(side)) {
        d.new_best_price = symbols_[s].window.tick_to_price(*best);
        d.new_best_size  = symbols_[s].ladder.level(side, *best).agg_size;
        d.flags          = 0x01;  // valid
      } else {
        d.flags = 0x02;  // side_empty
      }
      out.push_back(d);
    }
  }
  return out;
}

std::optional<TobDelta> Book::step(const BookEvent& ev) {
  ++stats_.events_in;
  if (ev.symbol_id >= n_symbols_) {
    return std::nullopt;
  }
  switch (static_cast<EventType>(ev.type)) {
    case EventType::Add:    return on_add(ev);
    case EventType::Delete: return on_delete(ev);
    case EventType::Cancel: return on_cancel(ev);
    case EventType::Exec:   return on_exec(ev);
    case EventType::ExecPx: return on_exec_px(ev);
  }
  return std::nullopt;
}

std::optional<TobDelta> Book::maybe_emit(const BookEvent& ev, uint8_t side,
                                          std::optional<uint32_t> prev_best,
                                          uint64_t prev_best_size,
                                          TobReason reason) {
  auto& sym = symbols_[ev.symbol_id];
  auto new_best = sym.ladder.best(side);
  uint64_t new_best_size =
      new_best ? sym.ladder.level(side, *new_best).agg_size : 0;
  // TOB delta fires on any change to the displayed top-of-book — price OR size.
  if (new_best == prev_best && new_best_size == prev_best_size) return std::nullopt;
  ++stats_.deltas_out;
  TobDelta d{};
  d.ingress_ts    = ev.ingress_ts;
  d.emit_ts       = ev.ingress_ts;
  d.symbol_id     = ev.symbol_id;
  d.side          = side;
  d.reason        = static_cast<uint8_t>(reason);
  if (new_best) {
    d.new_best_price = sym.window.tick_to_price(*new_best);
    d.new_best_size  = new_best_size;
    d.flags          = 0x01;
  } else {
    d.flags = 0x02;  // side_empty
  }
  return d;
}

std::optional<TobDelta> Book::on_add(const BookEvent& ev) {
  auto& sym = symbols_[ev.symbol_id];

  // Rebase if the incoming price is outside the window.
  if (sym.window.needs_rebase(ev.price)) {
    sym.window.rebase(sym.ladder, ev.price);
    ++stats_.rebases;
    // Stale slots in pool_ are intentionally leaked per sliding_window.h
    // FROZEN CONTRACT (drop-on-rebase). The M02 golden model has no
    // slow-path; pool capacity must absorb the leak across the replay window.
    id_map_.clear();
  }

  auto tick_opt = sym.window.price_to_tick(ev.price);
  if (!tick_opt) return std::nullopt;  // Defensive — post-rebase this shouldn't happen.
  auto tick = *tick_opt;

  auto prev_best = sym.ladder.best(ev.side);
  uint64_t prev_best_size =
      prev_best ? sym.ladder.level(ev.side, *prev_best).agg_size : 0;
  auto slot      = pool_.allocate();

  auto& rec     = pool_.at(slot);
  rec.order_id  = ev.order_id;
  rec.shares    = ev.shares;
  rec.price     = ev.price;
  rec.symbol_id = ev.symbol_id;
  rec.side      = ev.side;

  if (!id_map_.insert(ev.order_id, slot)) {
    ++stats_.duplicate_add;
    pool_.release(slot);
    return std::nullopt;
  }
  ++stats_.hash_inserts;

  sym.ladder.add(ev.side, tick, slot, ev.shares, pool_);
  sym.window.update_midprice(ev.price);

  return maybe_emit(ev, ev.side, prev_best, prev_best_size, TobReason::Add);
}

std::optional<TobDelta> Book::on_delete(const BookEvent& ev) {
  ++stats_.hash_lookups;
  auto slot_opt = id_map_.lookup(ev.order_id);
  if (!slot_opt) {
    ++stats_.hash_missed;
    return std::nullopt;
  }
  auto slot  = *slot_opt;
  auto& rec  = pool_.at(slot);
  auto& sym  = symbols_[rec.symbol_id];
  // id_map_ invariant: on_add clears id_map_ on rebase, so any order present
  // here was inserted post-rebase and its price is in the current window.
  auto tick  = *sym.window.price_to_tick(rec.price);

  auto prev_best  = sym.ladder.best(rec.side);
  uint64_t prev_best_size =
      prev_best ? sym.ladder.level(rec.side, *prev_best).agg_size : 0;
  sym.ladder.remove(rec.side, tick, slot, rec.shares, pool_);
  id_map_.erase(ev.order_id);
  // Save side and symbol BEFORE releasing the slot — pool_.release()
  // zero-fills the OrderRecord, so any read through `rec` afterwards
  // reads the wiped slot, not the original order.
  auto saved_side = rec.side;
  auto saved_sym  = rec.symbol_id;
  pool_.release(slot);

  BookEvent anchor = ev;
  anchor.symbol_id = saved_sym;
  return maybe_emit(anchor, saved_side, prev_best, prev_best_size, TobReason::Delete);
}

static std::optional<TobDelta> decrement_shares_common(
    Book& /*self*/, const BookEvent& ev, OrderPool& pool, OrderMap& id_map,
    std::vector<SymbolState>& symbols, BookStats& stats, TobReason reason) {
  ++stats.hash_lookups;
  auto slot_opt = id_map.lookup(ev.order_id);
  if (!slot_opt) {
    ++stats.hash_missed;
    return std::nullopt;
  }
  auto slot  = *slot_opt;
  auto& rec  = pool.at(slot);
  auto& sym  = symbols[rec.symbol_id];
  // id_map invariant: on_add clears id_map on rebase, so any order present
  // here was inserted post-rebase and its price is in the current window.
  auto tick  = *sym.window.price_to_tick(rec.price);

  auto prev_best = sym.ladder.best(rec.side);
  uint64_t prev_best_size =
      prev_best ? sym.ladder.level(rec.side, *prev_best).agg_size : 0;
  uint32_t delta = std::min<uint32_t>(rec.shares, ev.shares);
  rec.shares -= delta;
  // level_empty branch is unreachable: agg_size >= rec.shares before the
  // decrement (this order contributes rec.shares); after both decrement by
  // delta, agg_size >= rec.shares still holds, so rec.shares > 0 implies
  // agg_size > 0. The rec.shares == 0 case below covers all empty-level cases.
  sym.ladder.decrement_shares(rec.side, tick, delta);
  TobReason effective = reason;
  uint8_t saved_side = rec.side;
  uint16_t saved_sym = rec.symbol_id;

  if (rec.shares == 0) {
    sym.ladder.remove(rec.side, tick, slot, 0, pool);
    id_map.erase(ev.order_id);
    pool.release(slot);
    effective = TobReason::Delete;
  }

  // Manually re-run maybe_emit logic — this helper has its own `effective`
  // reason override so it cannot delegate to Book::maybe_emit.
  // TOB delta fires on any change to the displayed top-of-book — price OR size.
  auto& sym2 = symbols[saved_sym];
  auto new_best = sym2.ladder.best(saved_side);
  uint64_t new_best_size =
      new_best ? sym2.ladder.level(saved_side, *new_best).agg_size : 0;
  if (new_best == prev_best && new_best_size == prev_best_size) return std::nullopt;
  ++stats.deltas_out;
  TobDelta d{};
  d.ingress_ts = ev.ingress_ts;
  d.emit_ts    = ev.ingress_ts;
  d.symbol_id  = saved_sym;
  d.side       = saved_side;
  d.reason     = static_cast<uint8_t>(effective);
  if (new_best) {
    d.new_best_price = sym2.window.tick_to_price(*new_best);
    d.new_best_size  = new_best_size;
    d.flags          = 0x01;
  } else {
    d.flags = 0x02;
  }
  return d;
}

std::optional<TobDelta> Book::on_cancel(const BookEvent& ev) {
  return decrement_shares_common(*this, ev, pool_, id_map_, symbols_, stats_,
                                  TobReason::Cancel);
}
std::optional<TobDelta> Book::on_exec(const BookEvent& ev) {
  return decrement_shares_common(*this, ev, pool_, id_map_, symbols_, stats_,
                                  TobReason::Exec);
}
std::optional<TobDelta> Book::on_exec_px(const BookEvent& ev) {
  return decrement_shares_common(*this, ev, pool_, id_map_, symbols_, stats_,
                                  TobReason::ExecPx);
}

}  // namespace refbook
