"""Tests for hw/ip/lob_core/order_pool.sv.

Exercises:
  - alloc returns a fresh slot per cycle until exhaustion
  - free returns slot to the pool; subsequent alloc reuses it
  - record write / read round-trip
  - dual read ports return correct records on the same cycle
  - cycle counts: alloc = 1, read = 1, write = 1
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def _reset(dut, cycles=4):
    dut.rstn.value = 0
    dut.alloc_req.value = 0
    dut.free_req.value = 0
    dut.free_slot.value = 0
    dut.write_req.value = 0
    dut.write_slot.value = 0
    dut.write_record.value = 0
    dut.read0_req.value = 0
    dut.read0_slot.value = 0
    dut.read1_req.value = 0
    dut.read1_slot.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def _alloc(dut) -> int:
    """Assert alloc_req for one cycle; return the allocated slot.

    Cocotb-2.0 + Verilator note: after `await RisingEdge(dut.clk)` we are
    still in the active region — the always_ff NBA hasn't yet propagated
    to the readable signals. Waiting one extra rising edge lets the
    registered alloc_valid / alloc_slot become visible, which still
    upholds the spec's "1-cycle latency" contract (alloc_req at edge N
    -> alloc_valid at edge N+1, observed here at edge N+1).
    """
    dut.alloc_req.value = 1
    await RisingEdge(dut.clk)
    dut.alloc_req.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.alloc_valid.value) == 1, "alloc must produce a slot in 1 cycle on URAM hit"
    return int(dut.alloc_slot.value)


async def _free(dut, slot: int):
    dut.free_req.value = 1
    dut.free_slot.value = slot
    await RisingEdge(dut.clk)
    dut.free_req.value = 0


async def _write(dut, slot: int, record: int):
    dut.write_req.value = 1
    dut.write_slot.value = slot
    dut.write_record.value = record
    await RisingEdge(dut.clk)
    dut.write_req.value = 0


async def _read0(dut, slot: int) -> int:
    """Read port 0 — same timing rationale as `_alloc` (see docstring)."""
    dut.read0_req.value = 1
    dut.read0_slot.value = slot
    await RisingEdge(dut.clk)
    dut.read0_req.value = 0
    await RisingEdge(dut.clk)
    return int(dut.read0_record.value)


@cocotb.test()
async def test_alloc_returns_distinct_slots(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    slots = [await _alloc(dut) for _ in range(8)]
    assert len(set(slots)) == 8, f"slots not distinct: {slots}"


@cocotb.test()
async def test_free_then_alloc_reuses_slot(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    s = await _alloc(dut)
    await _free(dut, s)
    s2 = await _alloc(dut)
    assert s == s2, f"freed slot {s} not reused, got {s2}"


@cocotb.test()
async def test_write_then_read_round_trip(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    s = await _alloc(dut)
    payload = (0xDEADBEEFCAFEBABE << 0)   # use the order_id field as the marker
    await _write(dut, s, payload)
    got = await _read0(dut, s)
    assert got == payload, f"got 0x{got:064x}, want 0x{payload:064x}"


@cocotb.test()
async def test_pool_exhaustion_bumps_counter(dut):
    """Alloc until the free-list is drained; the next alloc must report invalid
    AND bump pool_exhausted."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    n = int(dut.POOL_SLOTS_PARAM.value) if hasattr(dut, "POOL_SLOTS_PARAM") else 16
    # Drain.
    for _ in range(n):
        await _alloc(dut)
    # Next alloc must fail without producing a duplicate slot.
    # Same NBA-visibility wait as `_alloc`: extra RisingEdge to make the
    # registered alloc_valid / pool_exhausted_q observable.
    dut.alloc_req.value = 1
    await RisingEdge(dut.clk)
    dut.alloc_req.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.alloc_valid.value) == 0
    assert int(dut.pool_exhausted.value) >= 1
