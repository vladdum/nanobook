#include <refbook/book.h>

#include <gtest/gtest.h>

using refbook::Book;
using refbook::BookEvent;
using refbook::EventType;
using refbook::TobReason;

static BookEvent make_add(uint16_t sym, uint8_t side, uint32_t price,
                          uint32_t shares, uint64_t order_id, uint64_t ts = 1) {
  BookEvent e{};
  e.type       = static_cast<uint8_t>(EventType::Add);
  e.side       = side;
  e.symbol_id  = sym;
  e.price      = price;
  e.shares     = shares;
  e.order_id   = order_id;
  e.ingress_ts = ts;
  return e;
}

TEST(BookAdd, FirstAddEmitsDelta) {
  Book b(10);
  auto d = b.step(make_add(3, 0, 1000000, 100, 42));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->symbol_id, 3u);
  EXPECT_EQ(d->side, 0u);
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Add));
  EXPECT_EQ(d->new_best_price, 1000000u);
  EXPECT_EQ(d->new_best_size, 100u);
}

TEST(BookAdd, NonImprovingAddEmitsNothing) {
  Book b(10);
  b.step(make_add(3, 0, 1000100, 50, 10));
  auto d = b.step(make_add(3, 0, 1000000, 100, 20));
  EXPECT_FALSE(d.has_value());
}

TEST(BookAdd, ImprovingAddEmitsDelta) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 50, 10));
  auto d = b.step(make_add(3, 0, 1000100, 100, 20));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->new_best_price, 1000100u);
}

TEST(BookAdd, DuplicateOrderIdCountedInStats) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 100, 42));
  b.step(make_add(3, 0, 1000000, 200, 42));  // duplicate id
  EXPECT_EQ(b.stats().duplicate_add, 1u);
}

TEST(BookAdd, IngressTimestampCopiedToDelta) {
  Book b(10);
  auto d = b.step(make_add(3, 0, 1000000, 100, 42, /*ts=*/987654321ULL));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->ingress_ts, 987654321ULL);
  EXPECT_EQ(d->emit_ts,    987654321ULL);
}
