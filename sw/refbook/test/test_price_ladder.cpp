#include <refbook/order_pool.h>
#include <refbook/price_ladder.h>

#include <gtest/gtest.h>

using refbook::OrderPool;
using refbook::PriceLadder;

TEST(PriceLadder, EmptyLadderHasNoBest) {
  PriceLadder l;
  EXPECT_FALSE(l.best(0).has_value());
  EXPECT_FALSE(l.best(1).has_value());
}

TEST(PriceLadder, AddSingleOrderMakesBestEqualTick) {
  OrderPool   pool(16);
  PriceLadder l;
  auto slot = pool.allocate();
  l.add(/*side=*/0, /*tick=*/2000, slot, /*shares=*/100, pool);
  ASSERT_TRUE(l.best(0).has_value());
  EXPECT_EQ(*l.best(0), 2000u);
  EXPECT_EQ(l.level(0, 2000).order_count, 1u);
  EXPECT_EQ(l.level(0, 2000).agg_size,    100u);
}

TEST(PriceLadder, BidBestIsHighestTick) {
  OrderPool   pool(16);
  PriceLadder l;
  l.add(0, 1000, pool.allocate(), 50, pool);
  l.add(0, 3000, pool.allocate(), 75, pool);
  l.add(0, 2000, pool.allocate(), 25, pool);
  EXPECT_EQ(*l.best(0), 3000u);
}

TEST(PriceLadder, AskBestIsLowestTick) {
  OrderPool   pool(16);
  PriceLadder l;
  l.add(1, 1000, pool.allocate(), 50, pool);
  l.add(1, 3000, pool.allocate(), 75, pool);
  l.add(1, 2000, pool.allocate(), 25, pool);
  EXPECT_EQ(*l.best(1), 1000u);
}

TEST(PriceLadder, RemoveEmptyingBestFindsNext) {
  OrderPool   pool(16);
  PriceLadder l;
  auto a = pool.allocate();
  auto b = pool.allocate();
  l.add(0, 3000, a, 50, pool);
  l.add(0, 2000, b, 25, pool);
  l.remove(0, 3000, a, 50, pool);
  EXPECT_EQ(*l.best(0), 2000u);
  EXPECT_EQ(l.level(0, 3000).order_count, 0u);
}

TEST(PriceLadder, PartialDecrementDoesNotClearLevel) {
  OrderPool   pool(16);
  PriceLadder l;
  auto s = pool.allocate();
  l.add(0, 2000, s, 100, pool);
  auto empty = l.decrement_shares(0, 2000, 60);
  EXPECT_FALSE(empty);
  EXPECT_EQ(l.level(0, 2000).agg_size, 40u);
}

TEST(PriceLadder, FullDecrementReportsEmpty) {
  OrderPool   pool(16);
  PriceLadder l;
  auto s = pool.allocate();
  l.add(0, 2000, s, 100, pool);
  auto empty = l.decrement_shares(0, 2000, 100);
  EXPECT_TRUE(empty);
  // Caller is responsible for calling remove() to clear bitmap.
}
