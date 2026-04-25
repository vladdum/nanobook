#include <refbook/order_pool.h>

#include <gtest/gtest.h>
#include <stdexcept>

using refbook::OrderPool;
using refbook::kNullSlot;

TEST(OrderPool, AllocateReturnsDistinctSlots) {
  OrderPool p(4);
  auto a = p.allocate();
  auto b = p.allocate();
  EXPECT_NE(a, b);
  EXPECT_LT(a, 4u);
  EXPECT_LT(b, 4u);
}

TEST(OrderPool, ReleaseMakesSlotReusable) {
  OrderPool p(2);
  auto a = p.allocate();
  p.release(a);
  auto b = p.allocate();
  EXPECT_EQ(a, b);
  EXPECT_EQ(p.active_count(), 1u);
}

TEST(OrderPool, ExhaustionThrows) {
  OrderPool p(2);
  p.allocate();
  p.allocate();
  EXPECT_THROW(p.allocate(), std::runtime_error);
}

TEST(OrderPool, AtReturnsMutableReference) {
  OrderPool p(2);
  auto s = p.allocate();
  p.at(s).order_id = 42;
  EXPECT_EQ(p.at(s).order_id, 42u);
}

TEST(OrderPool, InitialStateIsClean) {
  OrderPool p(4);
  EXPECT_EQ(p.capacity(), 4u);
  EXPECT_EQ(p.active_count(), 0u);
}

TEST(OrderPool, ReleaseAllRestoresCleanState) {
  OrderPool p(3);
  auto a = p.allocate();
  auto b = p.allocate();
  auto c = p.allocate();
  p.release(a); p.release(b); p.release(c);
  EXPECT_EQ(p.active_count(), 0u);
}
