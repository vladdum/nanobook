#include <refbook/order_map.h>

#include <gtest/gtest.h>

using refbook::OrderMap;

TEST(OrderMap, InsertAndLookup) {
  OrderMap m;
  EXPECT_TRUE(m.insert(1, 10));
  EXPECT_EQ(m.lookup(1), std::optional<uint32_t>{10});
}

TEST(OrderMap, LookupAbsentReturnsNullopt) {
  OrderMap m;
  EXPECT_EQ(m.lookup(99), std::nullopt);
}

TEST(OrderMap, DuplicateInsertFails) {
  OrderMap m;
  EXPECT_TRUE (m.insert(1, 10));
  EXPECT_FALSE(m.insert(1, 20));
  EXPECT_EQ(m.lookup(1), std::optional<uint32_t>{10});
}

TEST(OrderMap, EraseRemovesEntry) {
  OrderMap m;
  m.insert(1, 10);
  EXPECT_TRUE(m.erase(1));
  EXPECT_EQ(m.lookup(1), std::nullopt);
}

TEST(OrderMap, EraseAbsentReturnsFalse) {
  OrderMap m;
  EXPECT_FALSE(m.erase(99));
}

TEST(OrderMap, SizeReflectsInserts) {
  OrderMap m;
  m.insert(1, 10); m.insert(2, 20); m.insert(3, 30);
  EXPECT_EQ(m.size(), 3u);
  m.erase(2);
  EXPECT_EQ(m.size(), 2u);
}
