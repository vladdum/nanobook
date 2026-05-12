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
    dut.op_sym_idx.value = 0
    dut.op_side.value = 0
    dut.op_price.value = 0
    dut.op_slot.value = 0
    dut.op_shares.value = 0
    dut.op_partial.value = 0
    # F.2 §2: single-sym TBs use op_origin = WINDOW_BASE_TICK to recover the
    # pre-F.2 addressing (offset = price - WINDOW_BASE_TICK).
    dut.op_origin.value = 10000   # mirrors -GWINDOW_BASE_TICK=10000
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
    await RisingEdge(dut.clk)        # stage 0: capture op + URAM read
    dut.read_req.value = 0
    await RisingEdge(dut.clk)        # stage 1: read_head/etc. registered
    await RisingEdge(dut.clk)        # post 2026-05-13 amendment: outputs settle
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
    # Post 2026-05-13 amendment: OOW check fires at stage 1 (1 cycle after
    # input capture), so the counter is visible one cycle later than under
    # the M05 single-stage design.
    await RisingEdge(dut.clk)
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


# ---------------------------------------------------------------------------
# M06 helpers — multi-symbol addressing
# ---------------------------------------------------------------------------

async def _write_level_m06(dut, sym_idx, side, tick, slot, shares):
    """Drive add_req with sym_idx + side + price=tick + op_slot=slot + shares."""
    dut.op_sym_idx.value = sym_idx
    dut.op_side.value = side
    dut.op_price.value = tick
    dut.op_slot.value = slot
    dut.op_shares.value = shares
    dut.add_req.value = 1
    await RisingEdge(dut.clk)
    dut.add_req.value = 0


async def _read_level_m06(dut, sym_idx, side, tick) -> dict:
    dut.op_sym_idx.value = sym_idx
    dut.op_side.value = side
    dut.op_price.value = tick
    dut.read_req.value = 1
    await RisingEdge(dut.clk)        # stage 0: capture op + URAM read
    dut.read_req.value = 0
    await RisingEdge(dut.clk)        # stage 1: read_head/etc. registered
    await RisingEdge(dut.clk)        # post 2026-05-13 amendment: outputs settle
    return {
        "head": int(dut.read_head.value),
        "tail": int(dut.read_tail.value),
        "agg_size": int(dut.read_agg_size.value),
        "count": int(dut.read_count.value),
    }


@cocotb.test()
async def test_per_sym_isolation_m06(dut):
    """Writes on sym=0 tick=10010 don't disturb sym=1 tick=10010 readback.

    WINDOW_BASE_TICK=10000, so tick=10010 is offset 10 (well within the
    WINDOW_SIZE_TICKS=64 range configured in Makefile.price_ladder).
    """
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Write to sym=0, side=0, tick=10010
    await _write_level_m06(dut, sym_idx=0, side=0, tick=WINDOW_BASE + 10, slot=42, shares=100)
    # Write different values to sym=1, side=0, same tick
    await _write_level_m06(dut, sym_idx=1, side=0, tick=WINDOW_BASE + 10, slot=99, shares=200)
    # Read sym=0 — should reflect first write only
    level0 = await _read_level_m06(dut, sym_idx=0, side=0, tick=WINDOW_BASE + 10)
    assert level0["agg_size"] == 100, f"sym=0 agg={level0['agg_size']}, expected 100"
    # Read sym=1 — should reflect second write only
    level1 = await _read_level_m06(dut, sym_idx=1, side=0, tick=WINDOW_BASE + 10)
    assert level1["agg_size"] == 200, f"sym=1 agg={level1['agg_size']}, expected 200"
