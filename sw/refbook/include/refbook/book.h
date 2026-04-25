// SPDX-License-Identifier: Apache-2.0
// Book orchestrator — owns per-symbol state, dispatches events.
#pragma once

#include <refbook/book_event.h>
#include <refbook/order_map.h>
#include <refbook/order_pool.h>
#include <refbook/price_ladder.h>
#include <refbook/sliding_window.h>
#include <refbook/tob_delta.h>

#include <cstdint>
#include <optional>
#include <vector>

namespace refbook {

struct BookStats {
  uint64_t events_in      = 0;
  uint64_t deltas_out     = 0;
  uint64_t rebases        = 0;
  uint64_t hash_inserts   = 0;
  uint64_t hash_lookups   = 0;
  uint64_t hash_missed    = 0;   // DELETE/CANCEL for unknown order_id
  uint64_t duplicate_add  = 0;
};

struct SymbolState {
  PriceLadder   ladder{};
  SlidingWindow window;
  SymbolState() : window(0) {}
};

class Book {
 public:
  explicit Book(uint16_t n_symbols = 100,
                std::size_t pool_capacity = 1'000'000,
                uint32_t initial_midprice = 1000000 /* $100.0000 */);

  // Primary event entry point.
  std::optional<TobDelta> step(const BookEvent& ev);

  // Reset state, keep configuration.
  void reset();

  // Snapshot: for each (sym, side), emit current best as a TobDelta (or zero if empty).
  std::vector<TobDelta> snapshot() const;

  const BookStats& stats() const { return stats_; }

 private:
  std::optional<TobDelta> on_add     (const BookEvent&);
  std::optional<TobDelta> on_delete  (const BookEvent&);
  std::optional<TobDelta> on_cancel  (const BookEvent&);
  std::optional<TobDelta> on_exec    (const BookEvent&);
  std::optional<TobDelta> on_exec_px (const BookEvent&);

  std::optional<TobDelta> maybe_emit(const BookEvent& ev, uint8_t side,
                                     std::optional<uint32_t> prev_best,
                                     uint64_t prev_best_size,
                                     TobReason reason);

  uint16_t                 n_symbols_;
  OrderPool                pool_;
  OrderMap                 id_map_;
  std::vector<SymbolState> symbols_;
  BookStats                stats_{};
};

}  // namespace refbook
