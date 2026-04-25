#include <refbook/book.h>

#include <gtest/gtest.h>

using refbook::Book;
using refbook::BookEvent;
using refbook::EventType;
using refbook::TobReason;

static BookEvent make_add(uint16_t sym, uint8_t side, uint32_t price,
                          uint32_t shares, uint64_t order_id) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Add);
  e.side = side; e.symbol_id = sym; e.price = price; e.shares = shares;
  e.order_id = order_id; return e;
}

static BookEvent make_cancel(uint64_t order_id, uint32_t delta_shares) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Cancel);
  e.order_id = order_id; e.shares = delta_shares; return e;
}

static BookEvent make_exec(uint64_t order_id, uint32_t delta_shares) {
  BookEvent e{}; e.type = static_cast<uint8_t>(EventType::Exec);
  e.order_id = order_id; e.shares = delta_shares; return e;
}

TEST(BookCancelExec, PartialCancelUpdatesSize) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 100, 42));
  auto d = b.step(make_cancel(42, 30));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Cancel));
  EXPECT_EQ(d->new_best_size, 70u);
}

TEST(BookCancelExec, FullCancelBecomesDelete) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 100, 42));
  auto d = b.step(make_cancel(42, 100));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Delete));
  EXPECT_EQ(d->flags & 0x02, 0x02);  // side_empty
}

TEST(BookCancelExec, ExecUpdatesSizeOnly) {
  Book b(10);
  b.step(make_add(3, 0, 1000000, 100, 42));
  auto d = b.step(make_exec(42, 40));
  ASSERT_TRUE(d.has_value());
  EXPECT_EQ(d->reason, static_cast<uint8_t>(TobReason::Exec));
  EXPECT_EQ(d->new_best_size, 60u);
}

TEST(BookCancelExec, CancelBehindBestEmitsNothing) {
  Book b(10);
  b.step(make_add(3, 0, 1000100, 50, 10));
  b.step(make_add(3, 0, 1000000, 100, 20));
  auto d = b.step(make_cancel(20, 20));
  EXPECT_FALSE(d.has_value());
}
