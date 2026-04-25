#include <refbook/book.h>
#include <refbook/order_pool.h>

#include <gtest/gtest.h>

using refbook::Book;
using refbook::BookEvent;
using refbook::BookStats;
using refbook::EventType;
using refbook::OrderPool;
using refbook::TobReason;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static BookEvent make_add(uint16_t sym, uint8_t side, uint32_t price,
                          uint32_t shares, uint64_t order_id) {
  BookEvent e{};
  e.type = static_cast<uint8_t>(EventType::Add);
  e.side = side;
  e.symbol_id = sym;
  e.price = price;
  e.shares = shares;
  e.order_id = order_id;
  return e;
}

static BookEvent make_delete(uint64_t order_id) {
  BookEvent e{};
  e.type = static_cast<uint8_t>(EventType::Delete);
  e.order_id = order_id;
  return e;
}

static BookEvent make_cancel(uint64_t order_id, uint32_t delta_shares) {
  BookEvent e{};
  e.type = static_cast<uint8_t>(EventType::Cancel);
  e.order_id = order_id;
  e.shares = delta_shares;
  return e;
}

static BookEvent make_exec_px(uint64_t order_id, uint32_t delta_shares) {
  BookEvent e{};
  e.type = static_cast<uint8_t>(EventType::ExecPx);
  e.order_id = order_id;
  e.shares = delta_shares;
  return e;
}

// ---------------------------------------------------------------------------
// Test 1: Book::reset() clears stats and invalidates prior orders
// ---------------------------------------------------------------------------

TEST(BookCoverage, ResetClearsStats) {
  Book b(10);
  b.step(make_add(0, 0, 1000000, 100, 1));
  EXPECT_GT(b.stats().events_in, 0u);
  EXPECT_GT(b.stats().deltas_out, 0u);

  b.reset();

  EXPECT_EQ(b.stats().events_in, 0u);
  EXPECT_EQ(b.stats().deltas_out, 0u);
  EXPECT_EQ(b.stats().hash_inserts, 0u);
}

TEST(BookCoverage, ResetInvalidatesPriorOrderId) {
  Book b(10);
  b.step(make_add(0, 0, 1000000, 100, 42));

  b.reset();

  // After reset, order_id 42 is unknown — should bump hash_missed.
  auto d = b.step(make_delete(42));
  EXPECT_FALSE(d.has_value());
  EXPECT_EQ(b.stats().hash_missed, 1u);
}

// ---------------------------------------------------------------------------
// Test 2: Unknown EventType fallthrough — book.cpp line 58
// ---------------------------------------------------------------------------

TEST(BookCoverage, UnknownEventTypeFallthrough) {
  Book b(10);
  BookEvent e{};
  e.type = 99;  // no matching EventType case
  e.symbol_id = 0;
  auto d = b.step(e);
  EXPECT_FALSE(d.has_value());
  EXPECT_EQ(b.stats().events_in, 1u);
}

// ---------------------------------------------------------------------------
// Test 3: on_exec_px — book.cpp lines 238-240, case ExecPx line 56
// ---------------------------------------------------------------------------

TEST(BookCoverage, ExecPxPartialDecrement) {
  Book b(10);
  b.step(make_add(0, 0, 1000000, 100, 7));
  auto d = b.step(make_exec_px(7, 30));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::ExecPx));
  EXPECT_EQ(d->new_best_size, 70u);
}

TEST(BookCoverage, ExecPxFullExec) {
  Book b(10);
  b.step(make_add(0, 0, 1000000, 100, 8));
  auto d = b.step(make_exec_px(8, 100));
  ASSERT_TRUE(d.has_value());
  // Full removal → reason becomes Delete
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Delete));
  EXPECT_EQ(d->flags & 0x02, 0x02);  // side_empty
}

// ---------------------------------------------------------------------------
// Test 4: Book::snapshot() — book.cpp line 44 (return of snapshot)
// ---------------------------------------------------------------------------

TEST(BookCoverage, SnapshotEmptyBook) {
  Book b(2);
  auto snap = b.snapshot();
  // 2 symbols × 2 sides = 4 deltas, all side_empty (flags == 0x02)
  ASSERT_EQ(snap.size(), 4u);
  for (const auto& d : snap) {
    EXPECT_EQ(d.flags, 0x02) << "sym=" << d.symbol_id << " side=" << (int)d.side;
  }
}

TEST(BookCoverage, SnapshotWithActiveOrder) {
  Book b(2);
  b.step(make_add(0, 0, 1000000, 50, 99));
  auto snap = b.snapshot();
  ASSERT_EQ(snap.size(), 4u);
  // sym=0, side=0 (bid) should be valid
  EXPECT_EQ(snap[0].symbol_id, 0);
  EXPECT_EQ(snap[0].side, 0);
  EXPECT_EQ(snap[0].flags, 0x01);
  EXPECT_EQ(snap[0].new_best_size, 50u);
  // sym=0, side=1 (ask) should be side_empty
  EXPECT_EQ(snap[1].flags, 0x02);
}

// ---------------------------------------------------------------------------
// Test 5a: Stale-tick branch in on_delete — book.cpp lines 142-144
// ---------------------------------------------------------------------------

TEST(BookCoverage, DeleteStaleAfterRebase) {
  // Default midprice=1000000, window = [997952, 1002048)
  Book b(10);

  // Add order at price 1000000 (within window, order_id=1)
  b.step(make_add(0, 0, 1000000, 100, 1));

  // Add an order far outside the window to force a rebase.
  // New origin = 2000000 - 2048 = 1997952, window = [1997952, 2002048)
  // This also clears id_map_ on rebase, so order 1 gets purged from id_map.
  // We need order 1 to still be accessible by id — but rebase calls id_map_.clear().
  // So the stale path in on_delete requires the order to remain in id_map but
  // have a price outside the current window. We need to add order 1 AFTER
  // a first rebase settles, then force a second rebase.

  // Step A: settle at price 2000000 (order_id=2)
  b.step(make_add(0, 0, 2000000, 50, 2));
  // Window is now [1997952, 2002048). id_map cleared, order 1 gone from map.

  // Step B: add order at 2000000 to repopulate id_map
  b.step(make_add(0, 0, 2000000, 60, 3));

  // Step C: force a second rebase by adding far outside window again.
  // New origin = 3000000 - 2048 = 2997952, window = [2997952, 3002048).
  // id_map cleared again — order 3 gone.
  b.step(make_add(0, 0, 3000000, 40, 4));

  // Step D: add order at price 2000000 (stale: outside [2997952, 3002048))
  // but we must add it AFTER the current rebase so it IS in id_map.
  // We can't add at price 2000000 while window is [2997952, 3002048) because
  // on_add would rebase again. So let's craft the scenario more carefully:
  // Add order_id=5 at current window price 3000000, then rebase to 4000000.
  b.step(make_add(0, 0, 3000000, 70, 5));

  // Rebase: window moves to [4000000-2048, 4000000+2048). Order 5 is stale.
  // But id_map is cleared on rebase too, so order 5 is gone from map.
  b.step(make_add(0, 0, 4000000, 80, 6));

  // The on_delete stale path requires: order is IN id_map but its price is
  // outside the current window. The only way to achieve this without triggering
  // id_map_.clear() is to add the order AFTER the last rebase.
  // Let's add order_id=7 at 4000000 (in window), then rebase ONLY THE WINDOW
  // by triggering with order_id=8 at price 5000000.
  b.step(make_add(0, 0, 4000000, 90, 7));
  // Now rebase: window moves to [5000000-2048, 5000000+2048). id_map cleared, order 7 gone.
  // This approach always clears id_map on rebase — we can't get the stale path via on_add rebase.

  // REVISED APPROACH: Add order at price P in window. Then directly trigger the stale
  // path by adding the order to id_map at price P, then rebasing the window through
  // a different symbol so that order's symbol window moves but id_map is shared.
  // Actually id_map is per-Book (global), so any rebase on any symbol clears all of id_map.
  // The stale path in on_delete (book.cpp:141-144) requires:
  //   1. slot = id_map_.lookup(ev.order_id) succeeds → order IS in id_map
  //   2. sym.window.price_to_tick(rec.price) returns nullopt → price outside current window
  // With the current on_add rebase always doing id_map_.clear(), the only scenario where
  // an order is in id_map but its price is outside the window is if the order was added on
  // one symbol but another symbol's window is used — but id_map is global and price_to_tick
  // is looked up on rec.symbol_id's window. So if we add order on sym=0 at price P0,
  // then add an order on sym=1 at a far price causing rebase on sym=1 only (sym=0 not affected),
  // BUT on_add clears the GLOBAL id_map on rebase (line 98 of book.cpp).
  // Therefore, the on_delete stale path is UNREACHABLE with the current implementation
  // because id_map_.clear() on rebase always removes all orders before the stale window
  // state can be observed via on_delete.

  // Still, let's just verify the rebase + delete flow doesn't crash.
  auto d = b.step(make_delete(999));  // unknown order
  EXPECT_FALSE(d.has_value());
}

// ---------------------------------------------------------------------------
// Test 5b: Stale-tick branch in decrement_shares_common — book.cpp lines 178-180
// Same analysis applies: unreachable because id_map_.clear() on rebase removes all orders.
// We exercise the hash_missed path instead.
// ---------------------------------------------------------------------------

TEST(BookCoverage, CancelAfterRebaseHashMissed) {
  Book b(10);
  b.step(make_add(0, 0, 1000000, 100, 11));
  // Rebase: clears id_map, order 11 gone
  b.step(make_add(0, 0, 5000000, 50, 12));
  // Cancel for now-gone order 11 → hash_missed
  auto d = b.step(make_cancel(11, 30));
  EXPECT_FALSE(d.has_value());
  // hash_missed bumped (at least 1 from this cancel)
  EXPECT_GE(b.stats().hash_missed, 1u);
}

// ---------------------------------------------------------------------------
// Test 6: OrderPool::at(slot) const — order_pool.cpp lines 41-42
// ---------------------------------------------------------------------------

TEST(BookCoverage, OrderPoolConstAt) {
  OrderPool p(4);
  uint32_t slot = p.allocate();
  p.at(slot).order_id = 0xDEADBEEF;

  const OrderPool& cp = p;
  const auto& rec = cp.at(slot);
  EXPECT_EQ(rec.order_id, 0xDEADBEEFu);
}
