#include <refbook/book.h>
#include <refbook/book_event.h>

#include <benchmark/benchmark.h>

#include <random>

static void BM_StepAddOnly(benchmark::State& state) {
  // Pool sized for ~10M iterations (Google Benchmark auto-calibration target).
  refbook::Book b(100, 10'000'000);
  std::mt19937_64 rng(12345);
  uint64_t id = 0;
  for (auto _ : state) {
    refbook::BookEvent e{};
    e.type       = static_cast<uint8_t>(refbook::EventType::Add);
    e.symbol_id  = rng() % 100;
    e.side       = rng() & 1;
    e.price      = 1'000'000 + (int32_t(rng() % 2001) - 1000);
    e.shares     = 1 + (rng() % 1000);
    e.order_id   = ++id;
    e.ingress_ts = id;
    benchmark::DoNotOptimize(b.step(e));
  }
  state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_StepAddOnly);

static void BM_StepMixed(benchmark::State& state) {
  // Pool sized for ~10M iterations (Google Benchmark auto-calibration target).
  refbook::Book b(100, 10'000'000);
  std::mt19937_64 rng(42);
  uint64_t id = 0;
  std::vector<uint64_t> live;
  for (auto _ : state) {
    refbook::BookEvent e{};
    e.ingress_ts = ++id;
    if (live.empty() || (rng() % 100) < 60) {
      e.type = static_cast<uint8_t>(refbook::EventType::Add);
      e.symbol_id = rng() % 100;
      e.side      = rng() & 1;
      e.price     = 1'000'000 + (int32_t(rng() % 2001) - 1000);
      e.shares    = 1 + (rng() % 1000);
      e.order_id  = id;
      live.push_back(id);
    } else {
      auto victim = live[rng() % live.size()];
      e.type     = static_cast<uint8_t>(refbook::EventType::Delete);
      e.order_id = victim;
    }
    benchmark::DoNotOptimize(b.step(e));
  }
  state.SetItemsProcessed(state.iterations());
}
BENCHMARK(BM_StepMixed);

BENCHMARK_MAIN();
