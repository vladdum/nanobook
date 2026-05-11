"""Tests for hw/ip/lob_core/price_ladder.sv.

Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
  §3.2 (ADD pipeline + same-tick bypass), §3.3 (DELETE pipeline), §5.1.

The harness overrides WINDOW_BASE_TICK=10000 / WINDOW_SIZE_TICKS=64 (see
Makefile.price_ladder) so the out-of-window check fires on a small range.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


WINDOW_BASE = 10000
WINDOW_SIZE = 64


async def _reset(dut, cycles: int = 4) -> None:
    dut.rstn.value = 0
    dut.add_req.value = 0
    dut.del_req.value = 0
    dut.read_req.value = 0
    dut.op_side.value = 0
    dut.op_price.value = 0
    dut.op_slot.value = 0
    dut.op_shares.value = 0
    dut.op_partial.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def _add(dut, side: int, price: int, slot: int, shares: int) -> None:
    dut.add_req.value = 1
    dut.op_side.value = side
    dut.op_price.value = price
    dut.op_slot.value = slot
    dut.op_shares.value = shares
    await RisingEdge(dut.clk)
    dut.add_req.value = 0


async def _delete(dut, side: int, price: int, shares: int) -> None:
    dut.del_req.value = 1
    dut.op_side.value = side
    dut.op_price.value = price
    dut.op_shares.value = shares
    await RisingEdge(dut.clk)
    dut.del_req.value = 0


async def _read(dut, side: int, price: int) -> tuple[int, int, int, int]:
    dut.read_req.value = 1
    dut.op_side.value = side
    dut.op_price.value = price
    await RisingEdge(dut.clk)
    dut.read_req.value = 0
    await RisingEdge(dut.clk)   # 1-cycle URAM read latency
    return (
        int(dut.read_head.value),
        int(dut.read_tail.value),
        int(dut.read_agg_size.value),
        int(dut.read_count.value),
    )


@cocotb.test()
async def test_add_creates_level(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _add(dut, side=0, price=WINDOW_BASE + 5, slot=42, shares=100)
    head, tail, agg, count = await _read(dut, 0, WINDOW_BASE + 5)
    assert head == 42 and tail == 42, f"head={head} tail={tail}"
    assert agg == 100 and count == 1, f"agg={agg} count={count}"


@cocotb.test()
async def test_two_adds_link_correctly(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _add(dut, side=0, price=WINDOW_BASE + 5, slot=42, shares=100)
    await _add(dut, side=0, price=WINDOW_BASE + 5, slot=99, shares=200)
    head, tail, agg, count = await _read(dut, 0, WINDOW_BASE + 5)
    assert head == 42, f"head should remain first inserted slot, got {head}"
    assert tail == 99, f"tail should advance to latest slot, got {tail}"
    assert agg == 300 and count == 2, f"agg={agg} count={count}"


@cocotb.test()
async def test_out_of_window_bumps_counter(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _add(dut, side=0, price=WINDOW_BASE - 1, slot=1, shares=10)
    await RisingEdge(dut.clk)
    assert int(dut.out_of_window.value) >= 1, \
        f"out_of_window={int(dut.out_of_window.value)}"


@cocotb.test()
async def test_delete_decrements(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _add(dut, side=1, price=WINDOW_BASE + 7, slot=5, shares=200)
    await _add(dut, side=1, price=WINDOW_BASE + 7, slot=6, shares=200)
    await _delete(dut, side=1, price=WINDOW_BASE + 7, shares=200)
    _, _, agg, count = await _read(dut, 1, WINDOW_BASE + 7)
    assert agg == 200 and count == 1, f"agg={agg} count={count}"


@cocotb.test()
async def test_back_to_back_same_tick_no_stall(dut):
    """Spec §3.2 bypass requirement — back-to-back ADD on same tick must
    not stall. Drive two ADDs on consecutive cycles and confirm the second
    does NOT see stale agg_size."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    dut.add_req.value = 1
    dut.op_side.value = 0
    dut.op_price.value = WINDOW_BASE + 3
    dut.op_slot.value = 1
    dut.op_shares.value = 100
    await RisingEdge(dut.clk)
    dut.op_slot.value = 2
    dut.op_shares.value = 50
    await RisingEdge(dut.clk)
    dut.add_req.value = 0
    await RisingEdge(dut.clk)
    _, _, agg, count = await _read(dut, 0, WINDOW_BASE + 3)
    assert agg == 150, f"bypass failed: agg={agg}"
    assert count == 2, f"bypass failed: count={count}"
