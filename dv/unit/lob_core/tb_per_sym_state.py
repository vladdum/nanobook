"""Tests for hw/ip/lob_core/per_sym_state.sv.

Plan: docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md
      Task F.1.
Spec: design.md §3.5 — per-symbol {epoch, origin, midprice, rebase_count}.

per_sym_state is a 4-port distRAM-backed regfile (synchronous write, async
read) holding per-symbol state for the M06 sliding price window. On reset,
each entry initialises from lob_core_sym_pkg::INITIAL_MIDPRICE — origin =
midprice - WINDOW_HALF_TICKS (clamped at 0), epoch and rebase_count both 0.

Two write modes:
  write_kind=0  EMA midprice update — only midprice changes; epoch and
                rebase_count untouched.
  write_kind=1  Rebase — write_origin replaces origin; epoch++,
                rebase_count++; midprice latched from write_midprice.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


async def _reset(dut, cycles: int = 4) -> None:
    dut.rstn.value = 0
    dut.read_sym.value = 0
    dut.read2_sym.value = 0
    dut.write_en.value = 0
    dut.write_sym.value = 0
    dut.write_kind.value = 0
    dut.write_origin.value = 0
    dut.write_midprice.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset_initialises_from_init_array(dut):
    """After reset, epoch=0 and rebase_count=0 for every sym. With the
    standalone TB build (Makefile.per_sym_state does NOT include
    lob_core_sym_pkg), the INITIAL_MIDPRICE parameter defaults to all
    zeros, so midprice=0 and origin=max(0, 0-2048)=0. The lob_core smoke
    TB exercises the real INITIAL_MIDPRICE table via its package import."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    dut.read_sym.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == 0
    assert int(dut.read_rebase_count.value) == 0
    assert int(dut.read_midprice.value) == 0
    assert int(dut.read_origin.value) == 0


@cocotb.test()
async def test_rebase_write_bumps_epoch_and_count(dut):
    """write_kind=1 rebases sym=5: epoch++, rebase_count++, origin updates
    to write_origin, midprice updates to write_midprice."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    dut.write_sym.value = 5
    dut.write_origin.value = 1000
    dut.write_midprice.value = 3048
    dut.write_kind.value = 1
    dut.write_en.value = 1
    await RisingEdge(dut.clk)
    dut.write_en.value = 0
    # Async-read takes one cycle for cocotb's deferred write to settle.
    dut.read_sym.value = 5
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == 1
    assert int(dut.read_rebase_count.value) == 1
    assert int(dut.read_origin.value) == 1000
    assert int(dut.read_midprice.value) == 3048


@cocotb.test()
async def test_ema_write_does_not_bump_epoch(dut):
    """write_kind=0 (EMA) updates midprice ONLY — epoch / origin /
    rebase_count are untouched."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Capture sym=3's reset state.
    dut.read_sym.value = 3
    await RisingEdge(dut.clk)
    epoch_before  = int(dut.read_epoch.value)
    origin_before = int(dut.read_origin.value)
    rb_before     = int(dut.read_rebase_count.value)

    # EMA write on sym=3.
    dut.write_sym.value = 3
    dut.write_midprice.value = 1234
    dut.write_origin.value = 9999  # ignored for EMA
    dut.write_kind.value = 0
    dut.write_en.value = 1
    await RisingEdge(dut.clk)
    dut.write_en.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == epoch_before
    assert int(dut.read_origin.value) == origin_before
    assert int(dut.read_rebase_count.value) == rb_before
    assert int(dut.read_midprice.value) == 1234


@cocotb.test()
async def test_rebase_isolation_across_syms(dut):
    """Rebasing sym=5 does NOT perturb sym=6."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Snapshot sym=6 state.
    dut.read_sym.value = 6
    await RisingEdge(dut.clk)
    sym6_epoch  = int(dut.read_epoch.value)
    sym6_origin = int(dut.read_origin.value)
    sym6_mid    = int(dut.read_midprice.value)

    # Rebase sym=5.
    dut.write_sym.value = 5
    dut.write_origin.value = 500
    dut.write_midprice.value = 2548
    dut.write_kind.value = 1
    dut.write_en.value = 1
    await RisingEdge(dut.clk)
    dut.write_en.value = 0
    await RisingEdge(dut.clk)

    # sym=6 must be unchanged.
    dut.read_sym.value = 6
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value)    == sym6_epoch
    assert int(dut.read_origin.value)   == sym6_origin
    assert int(dut.read_midprice.value) == sym6_mid


@cocotb.test()
async def test_two_read_ports_independent(dut):
    """The 2nd read port lets lob_core's d3 stale-check read epoch for one
    sym while the ADD path reads another. Both ports must surface the same
    value when pointed at the same sym, and post-rebase the bumped epoch
    is visible on both."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Rebase sym=4 → epoch=1.
    dut.write_sym.value = 4
    dut.write_origin.value = 100
    dut.write_midprice.value = 2148
    dut.write_kind.value = 1
    dut.write_en.value = 1
    await RisingEdge(dut.clk)
    dut.write_en.value = 0
    await RisingEdge(dut.clk)
    # Read port 1 → sym=4 (post-rebase: epoch=1).
    # Read port 2 → sym=5 (untouched: epoch=0).
    dut.read_sym.value = 4
    dut.read2_sym.value = 5
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == 1
    assert int(dut.read2_epoch.value) == 0
    # Swap: read port 1 → sym=5, port 2 → sym=4.
    dut.read_sym.value = 5
    dut.read2_sym.value = 4
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == 0
    assert int(dut.read2_epoch.value) == 1


@cocotb.test()
async def test_two_back_to_back_rebases_increment_count_twice(dut):
    """Two rebase writes on the same sym → rebase_count=2, epoch=2."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    for origin, midprice in ((1000, 3048), (2000, 4048)):
        dut.write_sym.value = 7
        dut.write_origin.value = origin
        dut.write_midprice.value = midprice
        dut.write_kind.value = 1
        dut.write_en.value = 1
        await RisingEdge(dut.clk)
    dut.write_en.value = 0
    await RisingEdge(dut.clk)
    dut.read_sym.value = 7
    await RisingEdge(dut.clk)
    assert int(dut.read_epoch.value) == 2
    assert int(dut.read_rebase_count.value) == 2
    assert int(dut.read_origin.value) == 2000
    assert int(dut.read_midprice.value) == 4048
