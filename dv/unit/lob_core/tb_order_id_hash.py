"""Tests for hw/ip/lob_core/order_id_hash.sv.

Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
  §3.1, §3.3 step 1, §5.1, §5.3, §6.
Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 15.

Exercises:
  - insert / lookup round-trip
  - lookup of unknown order_id returns valid=0
  - delete then lookup returns valid=0 (tombstone)
  - probe-depth stat saturates and overflow counter bumps when MAX_PROBE_DEPTH
    is exceeded (forces collisions via brute-force xorshift64-mirror search).
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


N_SLOTS = 64
MAX_PROBE = 4


async def _reset(dut, cycles: int = 4) -> None:
    dut.rstn.value = 0
    dut.insert_req.value = 0
    dut.delete_req.value = 0
    dut.lookup_req.value = 0
    dut.order_id.value = 0
    dut.slot_idx_in.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def _insert(dut, oid: int, slot: int) -> bool:
    dut.insert_req.value = 1
    dut.order_id.value = oid
    dut.slot_idx_in.value = slot
    # Wait for op_done — variable-cycle (probe loop).
    for _ in range(MAX_PROBE + 4):
        await RisingEdge(dut.clk)
        if int(dut.op_done.value):
            ok = bool(int(dut.op_ok.value))
            dut.insert_req.value = 0
            return ok
    raise TimeoutError("insert never completed")


async def _lookup(dut, oid: int) -> tuple[bool, int]:
    dut.lookup_req.value = 1
    dut.order_id.value = oid
    for _ in range(MAX_PROBE + 4):
        await RisingEdge(dut.clk)
        if int(dut.op_done.value):
            found = bool(int(dut.op_ok.value))
            slot = int(dut.slot_idx_out.value)
            dut.lookup_req.value = 0
            return found, slot
    raise TimeoutError("lookup never completed")


async def _delete(dut, oid: int) -> bool:
    dut.delete_req.value = 1
    dut.order_id.value = oid
    for _ in range(MAX_PROBE + 4):
        await RisingEdge(dut.clk)
        if int(dut.op_done.value):
            ok = bool(int(dut.op_ok.value))
            dut.delete_req.value = 0
            return ok
    raise TimeoutError("delete never completed")


@cocotb.test()
async def test_insert_then_lookup(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    assert await _insert(dut, 0xCAFEBABEDEADBEEF, 17)
    found, slot = await _lookup(dut, 0xCAFEBABEDEADBEEF)
    assert found and slot == 17, f"expected (True, 17), got ({found}, {slot})"


@cocotb.test()
async def test_lookup_unknown_returns_invalid(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    found, _ = await _lookup(dut, 0x12345678)
    assert not found


@cocotb.test()
async def test_delete_then_lookup_returns_invalid(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    assert await _insert(dut, 42, 7)
    assert await _delete(dut, 42)
    found, _ = await _lookup(dut, 42)
    assert not found


@cocotb.test()
async def test_first_probe_two_cycle_latency(dut):
    """Single lookup on empty table: op_done asserts 2 cycles after req.

    Spec §3.6 (2026-05-11 amendment): registered URAM read pushes
    first-probe latency from 1 -> 2 cycles. A regression to combinational
    read would assert op_done at cycle 1.
    """
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    dut.lookup_req.value = 1
    dut.order_id.value = 0xDEADBEEF
    await RisingEdge(dut.clk)
    dut.lookup_req.value = 0
    # Cycle 1 after req: op_done MUST still be 0 (URAM read in flight).
    await RisingEdge(dut.clk)
    assert int(dut.op_done.value) == 0, (
        "op_done fired at cycle 1; registered URAM read regression"
    )
    # Cycle 2 after req: op_done MUST be 1 (read complete, op_ok=0 because miss).
    await RisingEdge(dut.clk)
    assert int(dut.op_done.value) == 1, "op_done failed to fire at cycle 2"
    assert int(dut.op_ok.value) == 0, "op_ok should be 0 for empty-table miss"


@cocotb.test()
async def test_lookup_different_bucket_after_insert(dut):
    """After inserting oid A, a lookup of oid B (different hash bucket)
    must report miss in EXACTLY 2 cycles via ST_FIRST — must NOT fall
    through to ST_PROBE. Regression on the row_first_probe_q stale-read
    bug from commit 481f294."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Insert oid A (let the existing _insert helper handle the wait).
    await _insert(dut, 0xAAAA_AAAA_AAAA_AAAA, 0x123456)
    # Now look up an oid that almost certainly hashes to a different
    # bucket. Use a value far from 0xAA...AA after xorshift64 mixing.
    dut.lookup_req.value = 1
    dut.order_id.value = 0x0000_0000_0000_0001
    await RisingEdge(dut.clk)
    dut.lookup_req.value = 0
    # Cycle 1 after req: still in ST_FIRST setup; op_done must be 0.
    await RisingEdge(dut.clk)
    assert int(dut.op_done.value) == 0, "op_done fired at cycle 1"
    # Cycle 2 after req: ST_FIRST decides on table_ram[hash(B)] (empty).
    # op_done=1, op_ok=0. probe_max stays at 1 (NOT 2) — proves no probe
    # fallthrough happened.
    await RisingEdge(dut.clk)
    assert int(dut.op_done.value) == 1, "op_done failed at cycle 2"
    assert int(dut.op_ok.value) == 0, "op_ok should be 0 (miss)"
    # Drain one extra cycle, then read probe_max.
    await RisingEdge(dut.clk)
    assert int(dut.hash_probe_max.value) == 1, (
        f"hash_probe_max = {int(dut.hash_probe_max.value)}, expected 1 — "
        "lookup fell through to ST_PROBE (stale row_first_probe_q bug)"
    )


@cocotb.test()
async def test_probe_depth_saturates(dut):
    """Force collisions by inserting many oids that hash to the same bucket
    (Phase B pinned xorshift64 — _emulate_hash mirrors the RTL hash64()).
    First MAX_PROBE inserts succeed; the 5th+ should overflow."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    bucket = 0
    chosen: list[int] = []
    for oid in range(1, 1 << 20):
        if (_emulate_hash(oid) % N_SLOTS) == bucket:
            chosen.append(oid)
            if len(chosen) == 6:
                break
    assert len(chosen) == 6, f"collision finder failed: only {len(chosen)} oids in 1M attempts"

    inserts_ok = 0
    for oid in chosen:
        if await _insert(dut, oid, oid & 0xFFFF):
            inserts_ok += 1
    # First MAX_PROBE inserts should succeed; the 5th+ should overflow.
    assert inserts_ok == MAX_PROBE, f"expected {MAX_PROBE} OK inserts, got {inserts_ok}"
    assert int(dut.hash_overflow.value) >= len(chosen) - MAX_PROBE
    assert int(dut.hash_probe_max.value) == MAX_PROBE


def _emulate_hash(oid: int) -> int:
    """Mirror hw/ip/lob_core/order_id_hash.sv hash64() for HASH_FN=HASH_XORSHIFT64.
    Phase B pinned xorshift64; if Phase B re-pins, this must be updated in lockstep."""
    x = (oid ^ 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF
    x ^= (x >> 7)
    x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
    return x & 0xFFFFFFFFFFFFFFFF
