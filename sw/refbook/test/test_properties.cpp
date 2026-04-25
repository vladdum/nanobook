#include <refbook/book.h>

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <random>
#include <unordered_set>

using refbook::Book;
using refbook::BookEvent;
using refbook::EventType;

namespace {

struct Harness {
  Book b;
  std::mt19937_64 rng;
  uint64_t next_id = 1;
  std::unordered_set<uint64_t> live;

  Harness(uint64_t seed) : b(10), rng(seed) {}

  void step_random() {
    uint32_t choice = rng() % 100;
    BookEvent e{};
    if (choice < 60 || live.empty()) {
      // ADD
      e.type      = static_cast<uint8_t>(EventType::Add);
      e.symbol_id = rng() % 10;
      e.side      = rng() & 1;
      e.price     = 1'000'000 + (rng() % 2000) - 1000;  // close to midprice
      e.shares    = 1 + (rng() % 100);
      e.order_id  = next_id++;
      e.ingress_ts = next_id;
      live.insert(e.order_id);
    } else if (choice < 80) {
      // DELETE a live order
      auto it = live.begin();
      std::advance(it, rng() % live.size());
      e.type     = static_cast<uint8_t>(EventType::Delete);
      e.order_id = *it;
      live.erase(it);
    } else {
      // CANCEL a partial
      auto it = live.begin();
      std::advance(it, rng() % live.size());
      e.type     = static_cast<uint8_t>(EventType::Cancel);
      e.order_id = *it;
      e.shares   = 1 + (rng() % 50);
    }
    b.step(e);
  }

  void assert_invariants() {
    // Hash map size == active orders in pool (counted externally via stats).
    // Properties checked via snapshot consistency.
    auto snap = b.snapshot();
    for (auto& d : snap) {
      if (d.flags & 0x01) {
        EXPECT_GT(d.new_best_size, 0u) << "valid side with zero best_size";
      }
    }
  }
};

}  // namespace

TEST(Properties, RandomStream10kEvents) {
  Harness h(42);
  for (int i = 0; i < 10000; ++i) {
    h.step_random();
    if (i % 500 == 0) h.assert_invariants();
  }
  h.assert_invariants();
}

TEST(Properties, SeededRunIsDeterministic) {
  Harness h1(123), h2(123);
  for (int i = 0; i < 1000; ++i) { h1.step_random(); h2.step_random(); }
  // Snapshots byte-identical.
  auto s1 = h1.b.snapshot();
  auto s2 = h2.b.snapshot();
  ASSERT_EQ(s1.size(), s2.size());
  for (std::size_t i = 0; i < s1.size(); ++i) {
    EXPECT_EQ(std::memcmp(&s1[i], &s2[i], sizeof(refbook::TobDelta)), 0)
        << "snapshot divergence at index " << i;
  }
}
