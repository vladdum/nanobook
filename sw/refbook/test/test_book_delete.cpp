#include <refbook/book.h>

#include <gtest/gtest.h>

using refbook::Book;
using refbook::BookEvent;
using refbook::EventType;
using refbook::TobReason;

static BookEvent make_add(uint16_t sym, uint8_t side, uint32_t price,
                          uint32_t shares, uint64_t order_id, uint64_t ts = 1) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Add);
  e.side = side; e.symbol_id = sym; e.price = price; e.shares = shares;
  e.order_id = order_id; e.ingress_ts = ts; return e;
}

static BookEvent make_del(uint64_t order_id, uint64_t ts = 2) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Delete);
  e.order_id = order_id; e.ingress_ts = ts; return e;
}

TEST(BookDelete, DeleteOnlyOrderEmptiesSide) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 100, 42));
  auto d = b.step(make_del(42));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Delete));
  EXPECT_EQ(d->flags & 0x02, 0x02);  // side_empty
}

TEST(BookDelete, DeleteBehindBestEmitsNothing) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 50, 10));    // best
  b.step(make_add(3, 0, 999900,  100, 20));   // behind best
  auto d = b.step(make_del(20));
  EXPECT_FALSE(d.has_value());
}

TEST(BookDelete, DeleteUnknownOrderIsNoop) {
  Book b(10);
  auto d = b.step(make_del(999));
  EXPECT_FALSE(d.has_value());
  EXPECT_EQ(b.stats().hash_missed, 1u);
}

TEST(BookDelete, DeleteBestExposesNextBest) {
  Book b(10);
  b.step(make_add(3, 0, 1000100, 50, 10));  // best
  b.step(make_add(3, 0, 1000000, 100, 20)); // second
  auto d = b.step(make_del(10));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->new_best_price, 1000000u);
  EXPECT_EQ(d->new_best_size, 100u);
}
