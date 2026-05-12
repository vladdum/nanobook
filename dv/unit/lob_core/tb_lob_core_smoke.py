"""Minimal smoke TB: drive a few book_event_t beats, confirm the orchestrator
accepts them and bumps `events_in` once the pipeline drains.

Phase C (stub) asserted m_tvalid==0; Phase H wires the real datapath through
to tob_tracker, so 5 distinct-price ADDs do produce TOB deltas. The smoke
TB now drains the pipeline before reading events_in (which bumps at retire,
NOT at handshake — see lob_core.sv Phase H header)."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


@cocotb.test()
async def test_stub_accepts_events(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.m_tready.value = 1
    dut.dbg_epoch_bump.value = 0
    for i in range(5):
        ev = _book.pack_book_event(
            ev_type=0,    # EV_ADD
            side=0,
            symbol_id=5754,
            price=10000 + i,
            shares=100,
            order_id=1000 + i,
            ingress_ts=i,
        )
        await _book.push_event(dut, ev)
    # Drain the 4-stage ADD pipeline (events_in bumps at retire).
    for _ in range(12):
        await RisingEdge(dut.clk)
    assert int(dut.events_in.value) == 5, f"got events_in={int(dut.events_in.value)}"


@cocotb.test()
async def test_stale_delete_silent_drops_and_frees_slot(dut):
    """ADD an order at epoch 0, bump the stub epoch to 1 (simulating a
    rebase event), then send a DELETE for the same order_id.  The stale_check
    stage should silently free the pool slot + erase the hash entry without
    emitting a TOB delta.  stale_drops and pool_leaks_freed each bump by 1.

    Uses stock_locate=5754 — the M06 sym_idx_lut maps it to sym_idx=0 so
    the ADD survives the LUT filter; price 10000 is inside the smoke
    Makefile's WINDOW_BASE_TICK=10000 / WINDOW_SIZE_TICKS=64 window."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.dbg_epoch_bump.value = 0
    dut.m_tready.value = 1

    # ADD order_id=9999 at epoch 0 (stub epoch starts at 0 after reset).
    ev_add = _book.pack_book_event(
        ev_type=0, side=0, symbol_id=5754,
        price=10000, shares=10, order_id=9999, ingress_ts=0,
    )
    await _book.push_event(dut, ev_add)
    # Drain the ADD pipeline so the order is fully committed.
    deltas = await _book.collect_deltas(dut, n=1, max_cycles=20)
    assert len(deltas) == 1, f"ADD should produce 1 TOB delta, got {len(deltas)}"

    # Backdoor: bump _stub_epoch_q from 0 → 1 (rebase simulation).
    dut.dbg_epoch_bump.value = 1
    await RisingEdge(dut.clk)
    dut.dbg_epoch_bump.value = 0
    await RisingEdge(dut.clk)

    # Capture counters before the DELETE.
    pre_stale = int(dut.stale_drops.value)
    pre_freed = int(dut.pool_leaks_freed.value)

    # DELETE order_id=9999 → stale_check fires at d3 (ins_epoch=0 ≠ epoch=1).
    ev_del = _book.pack_book_event(
        ev_type=1, side=0, symbol_id=5754,
        price=0, shares=0, order_id=9999, ingress_ts=10,
    )
    await _book.push_event(dut, ev_del)

    # Watch for 30 cycles; m_tvalid must stay low (silent drop).
    dut.m_tready.value = 1
    for _ in range(30):
        await RisingEdge(dut.clk)
        assert int(dut.m_tvalid.value) == 0, \
            "stale DELETE must not emit a TOB delta"

    assert int(dut.stale_drops.value) - pre_stale == 1, \
        f"stale_drops should bump by 1, got {int(dut.stale_drops.value) - pre_stale}"
    assert int(dut.pool_leaks_freed.value) - pre_freed == 1, \
        f"pool_leaks_freed should bump by 1, got {int(dut.pool_leaks_freed.value) - pre_freed}"
