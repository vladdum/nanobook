"""Tests for sw.m05_tools.hash_sim — exercises the open-addressing model
on tiny synthetic order_id sequences."""
from __future__ import annotations

from sw.m05_tools.hash_sim import (
    Probe,
    crc32_low64,
    fibonacci_mul,
    simulate_open_addressing,
    xorshift64,
)


def test_xorshift64_deterministic() -> None:
    assert xorshift64(0) != 0   # 0 input gets seeded to non-zero
    assert xorshift64(1) == xorshift64(1)
    assert xorshift64(1) != xorshift64(2)


def test_simulate_no_collision_under_low_load() -> None:
    n_slots = 1024
    inserts = [(i, "ADD") for i in range(100)]   # << 1024 slots
    probe = simulate_open_addressing(inserts, n_slots, xorshift64)
    assert probe.worst_probe <= 4
    assert probe.peak_load_factor < 0.2


def test_delete_then_reinsert_does_not_inflate_probe() -> None:
    """Tombstone handling: deleted slots must be reusable for inserts."""
    n_slots = 32
    seq: list[tuple[int, str]] = []
    for i in range(20):
        seq.append((i, "ADD"))
    for i in range(20):
        seq.append((i, "DELETE"))
    for i in range(100, 120):
        seq.append((i, "ADD"))
    probe = simulate_open_addressing(seq, n_slots, xorshift64)
    assert probe.peak_load_factor <= 20 / 32 + 1e-6   # never exceeds first batch
    assert probe.worst_probe < n_slots, "should not require full-table scan"


def test_alternative_hashes_round_trip() -> None:
    """Both crc32 and fibonacci_mul should be deterministic and finite."""
    for fn in (crc32_low64, fibonacci_mul):
        assert fn(42) == fn(42)
        assert 0 <= fn(0xCAFEBABEDEADBEEF) < (1 << 64) or 0 <= fn(0xCAFEBABEDEADBEEF) < (1 << 32)
