#include <refbook/book.h>

#include <gtest/gtest.h>

using refbook::Book;
using refbook::BookEvent;
using refbook::EventType;

static BookEvent make_add(uint16_t sym, uint8_t side, uint32_t price,
                          uint32_t shares, uint64_t order_id) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Add);
  e.side = side; e.symbol_id = sym; e.price = price; e.shares = shares;
  e.order_id = order_id; return e;
}

TEST(BookMultiSymbol, SymbolsAreIndependent) {
  Book b(100);
  b.step(make_add(5,  0, 1000000, 100, 1));
  b.step(make_add(50, 0, 2000000, 200, 2));
  auto snap = b.snapshot();
  ASSERT_EQ(snap.size(), 200u);
  EXPECT_EQ(snap[5  * 2 + 0].new_best_price, 1000000u);
  EXPECT_EQ(snap[50 * 2 + 0].new_best_price, 2000000u);
}

TEST(BookMultiSymbol, OutOfRangeSymbolIsNoop) {
  Book b(10);
  auto d = b.step(make_add(99, 0, 1000000, 100, 1));
  EXPECT_FALSE(d.has_value());
}

TEST(BookMultiSymbol, StressAddDelete100Symbols) {
  Book b(100);
  for (uint16_t s = 0; s < 100; ++s) {
    b.step(make_add(s, 0, 1000000 + s, 100 + s, 1000 + s));
  }
  EXPECT_EQ(b.stats().events_in,  100u);
  EXPECT_EQ(b.stats().deltas_out, 100u);
}
