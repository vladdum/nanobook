#include <refbook/price_ladder.h>
#include <refbook/sliding_window.h>

#include <gtest/gtest.h>

using refbook::PriceLadder;
using refbook::SlidingWindow;

TEST(SlidingWindow, PriceInsideWindowMapsToTick) {
  SlidingWindow w(100000);   // origin = 100000 - 2048 = 97952
  ASSERT_TRUE(w.price_to_tick(100000).has_value());
  EXPECT_EQ(*w.price_to_tick(100000), 2048u);
  EXPECT_EQ(*w.price_to_tick(97952),  0u);
  EXPECT_EQ(*w.price_to_tick(101999), 4047u);
}

TEST(SlidingWindow, PriceOutsideWindowReturnsNullopt) {
  SlidingWindow w(100000);
  EXPECT_FALSE(w.price_to_tick(97951).has_value());
  EXPECT_FALSE(w.price_to_tick(102048).has_value());
}

TEST(SlidingWindow, TickToPriceInverse) {
  SlidingWindow w(100000);
  EXPECT_EQ(w.tick_to_price(2048), 100000u);
  EXPECT_EQ(w.tick_to_price(0),    97952u);
}

TEST(SlidingWindow, NeedsRebaseOnFarPrice) {
  SlidingWindow w(100000);
  EXPECT_FALSE(w.needs_rebase(100500));
  EXPECT_TRUE (w.needs_rebase(200000));
  EXPECT_TRUE (w.needs_rebase(50000));
}

TEST(SlidingWindow, EmaMovesMidprice) {
  SlidingWindow w(100000);
  for (int i = 0; i < 1000; ++i) w.update_midprice(110000);
  // After many updates, midprice converges toward 110000.
  EXPECT_GT(w.midprice(), 109000u);
}

TEST(SlidingWindow, RebaseDropsLadderAndRecenters) {
  SlidingWindow w(100000);
  PriceLadder   l;
  refbook::OrderPool pool(16);
  auto s = pool.allocate();
  l.add(0, *w.price_to_tick(100000), s, 100, pool);
  w.rebase(l, 200000);
  // M02 contract: rebase drops the entire ladder and re-centers on the
  // triggering price. The order at the old tick is gone from the new ladder.
  EXPECT_EQ(w.rebase_count(), 1u);
  EXPECT_FALSE(l.best(0).has_value());     // ladder dropped
  EXPECT_EQ(w.origin(),   197952u);        // 200000 - 2048
  EXPECT_EQ(w.midprice(), 200000u);        // post-rebase midprice = trigger price
}
