// Streams 10M synthetic events through refbook and asserts SHA-256 of the
// emitted TobDelta byte stream matches the committed expected value.

#include <refbook/book.h>
#include <refbook/book_event.h>

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Minimal SHA-256 (public-domain); streaming interface.
namespace sha256 {
struct Ctx { uint32_t s[8]; uint64_t n; uint8_t buf[64]; std::size_t bl; };
static inline uint32_t rr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }
static void init(Ctx& c) {
  static const uint32_t I[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                                0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  std::memcpy(c.s, I, sizeof(I)); c.n = 0; c.bl = 0;
}
static void compress(Ctx& c, const uint8_t* p) {
  static const uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
  uint32_t w[64];
  for (int i = 0; i < 16; ++i)
    w[i] = (uint32_t)p[i*4]<<24 | (uint32_t)p[i*4+1]<<16 | (uint32_t)p[i*4+2]<<8 | p[i*4+3];
  for (int i = 16; i < 64; ++i) {
    uint32_t s0 = rr(w[i-15],7) ^ rr(w[i-15],18) ^ (w[i-15]>>3);
    uint32_t s1 = rr(w[i-2],17) ^ rr(w[i-2],19)  ^ (w[i-2]>>10);
    w[i] = w[i-16] + s0 + w[i-7] + s1;
  }
  uint32_t a=c.s[0],b=c.s[1],d=c.s[2],e=c.s[3],f=c.s[4],g=c.s[5],h=c.s[6],i2=c.s[7];
  for (int i = 0; i < 64; ++i) {
    uint32_t S1 = rr(f,6)^rr(f,11)^rr(f,25);
    uint32_t ch = (f & g) ^ (~f & h);
    uint32_t t1 = i2 + S1 + ch + K[i] + w[i];
    uint32_t S0 = rr(a,2)^rr(a,13)^rr(a,22);
    uint32_t mj = (a & b) ^ (a & d) ^ (b & d);
    uint32_t t2 = S0 + mj;
    i2 = h; h = g; g = f; f = e + t1;
    e = d; d = b; b = a; a = t1 + t2;
  }
  c.s[0]+=a;c.s[1]+=b;c.s[2]+=d;c.s[3]+=e;c.s[4]+=f;c.s[5]+=g;c.s[6]+=h;c.s[7]+=i2;
}
static void update(Ctx& c, const uint8_t* p, std::size_t n) {
  c.n += n;
  while (n) {
    std::size_t k = std::min<std::size_t>(64 - c.bl, n);
    std::memcpy(c.buf + c.bl, p, k);
    c.bl += k; p += k; n -= k;
    if (c.bl == 64) { compress(c, c.buf); c.bl = 0; }
  }
}
static std::string final_hex(Ctx& c) {
  uint64_t nb = c.n * 8;
  uint8_t pad = 0x80;
  update(c, &pad, 1);
  uint8_t zero = 0;
  while (c.bl != 56) update(c, &zero, 1);
  uint8_t nbuf[8];
  for (int i = 0; i < 8; ++i) nbuf[i] = (nb >> ((7 - i) * 8)) & 0xFF;
  update(c, nbuf, 8);
  static const char hex[] = "0123456789abcdef";
  std::string out;
  for (int i = 0; i < 8; ++i) {
    for (int j = 3; j >= 0; --j) {
      uint8_t b = (c.s[i] >> (j * 8)) & 0xFF;
      out.push_back(hex[b >> 4]); out.push_back(hex[b & 0xF]);
    }
  }
  return out;
}
}  // namespace sha256

// Minimal in-file replica of synthetic_gen.py's logic to keep the gate
// self-contained. See Task 24 for the canonical Python form.
//
// Uses parallel vector + unordered_map for O(1) random victim sampling
// (swap-pop on erase). RNG draw count per event matches the Python form.
static void run_stream(refbook::Book& book, uint64_t seed,
                       int n_symbols, int n_events, sha256::Ctx& hctx) {
  std::mt19937_64 rng(seed);
  struct Live { uint16_t sym; uint8_t side; uint32_t price; uint32_t shares; };
  std::vector<uint64_t> live_ids;
  std::unordered_map<uint64_t, Live> live_data;
  uint64_t next_id = 1;
  auto swap_pop = [&](std::size_t idx, uint64_t id) {
    live_ids[idx] = live_ids.back();
    live_ids.pop_back();
    live_data.erase(id);
  };
  for (int i = 0; i < n_events; ++i) {
    refbook::BookEvent e{};
    e.ingress_ts = static_cast<uint64_t>(i + 1);
    uint32_t choice = rng() % 100;
    if (live_ids.empty() || choice < 60) {
      e.type      = static_cast<uint8_t>(refbook::EventType::Add);
      e.symbol_id = rng() % n_symbols;
      e.side      = rng() & 1;
      e.price     = 1'000'000 + (int32_t(rng() % 2001) - 1000);
      e.shares    = 1 + (rng() % 1000);
      e.order_id  = next_id++;
      live_ids.push_back(e.order_id);
      live_data[e.order_id] = {e.symbol_id, e.side, e.price, e.shares};
    } else {
      std::size_t idx = rng() % live_ids.size();
      uint64_t id = live_ids[idx];
      Live lv = live_data[id];
      uint32_t roll = rng() % 100;
      if (roll < 40) {
        e.type = static_cast<uint8_t>(refbook::EventType::Delete);
        e.order_id = id;
        swap_pop(idx, id);
      } else {
        uint32_t delta = 1 + (rng() % lv.shares);
        e.type     = static_cast<uint8_t>(
            roll < 70 ? refbook::EventType::Cancel : refbook::EventType::Exec);
        e.order_id = id; e.shares = delta;
        if (delta >= lv.shares) swap_pop(idx, id);
        else                    live_data[id].shares -= delta;
      }
    }
    auto d = book.step(e);
    if (d) {
      sha256::update(hctx, reinterpret_cast<const uint8_t*>(&*d), sizeof(*d));
    }
  }
}

TEST(Reproducibility, TenMillionEventsSha256) {
  // Pool sized for measured peak live ~4.4M at (seed=42, n_symbols=100, n_events=10M).
  refbook::Book b(100, 5'000'000);
  sha256::Ctx c; sha256::init(c);
  run_stream(b, 42, 100, 10'000'000, c);
  std::string got = sha256::final_hex(c);

  std::ifstream f("test/reproducibility_expected.sha256");
  std::string expected; f >> expected;
  if (expected.empty()) {
    GTEST_FAIL() << "expected-SHA file empty; first-run result = " << got;
  }
  EXPECT_EQ(got, expected);
}
