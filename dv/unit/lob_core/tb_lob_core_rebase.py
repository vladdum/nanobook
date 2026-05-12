"""Tests for the F.2 inline rebase trigger.

Plan: docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md
      Task F.2.

The minimal F.2 implementation:
  - Instantiates per_sym_state in lob_core.
  - On an OOW ADD (price outside [WINDOW_BASE_TICK, WINDOW_BASE_TICK +
    WINDOW_SIZE_TICKS)), writes pss with write_kind=1 (rebase) →
    epoch++, rebase_count++, origin = price - WINDOW_HALF_TICKS,
    midprice = price; bumps rebases_total_q.
  - Stamps a1_pl_q.ins_epoch with (pss_read_epoch + add_rebase_trigger),
    so subsequent DELs against pre-rebase orders read a mismatched
    ins_epoch at d3 and silently drop (stale_drops bumps).

Deferred to follow-up (alongside Phase H cosim):
  - Squash-and-retry of the rebase-triggering ADD itself (it is currently
    dropped by the pre-rebase WINDOW_BASE_TICK in-window check; the
    rebase fires but the ADD's bitmap/ladder write does not happen).
  - Per-sym ladder address math using pss_read_origin instead of the
    static WINDOW_BASE_TICK.
  - Cross-side silent-empty on rebase (refbook drops the cross-side
    when a rebase clears the ladder; the M06 RTL is not yet capable of
    that semantics).

The Makefile reuses Makefile.smoke's sizing (WINDOW_BASE_TICK=10000,
WINDOW_SIZE_TICKS=64). Locate 5754 is the AAPL slot (sym_idx=0).
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


SYM = 5754  # stock_locate, AAPL → sym_idx 0 in the LUT
EV_ADD     = 0
EV_DELETE  = 2


@cocotb.test()
async def test_oow_add_triggers_rebase_and_completes(dut):
    """An ADD with price outside the per-sym window fires the rebase
    trigger; rebases_total bumps by 1. F.2 §4 squash-and-retry then
    re-presents the ADD against the post-rebase origin, so the ADD
    itself ALSO retires (events_in bumps) and emits a tob_delta."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.dbg_epoch_bump.value = 0
    dut.m_tready.value = 1
    pre_rebases  = int(dut.rebases_total.value)
    pre_events   = int(dut.events_in.value)
    pre_deltas   = int(dut.tob_deltas_out.value)
    # sym=0 origin set to 10000 by _book.reset()'s backdoor (window
    # [10000, 10064)). Price 50000 is OOW → triggers rebase → new
    # origin = 50000 - 32 = 49968 (smoke WINDOW_SIZE_TICKS=64, half = 32).
    # Re-presented ADD at price 50000 lands in [49968, 50032).
    ev = _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM,
        price=50000, shares=10, order_id=1, ingress_ts=0,
    )
    await _book.push_event(dut, ev)
    for _ in range(16):
        await RisingEdge(dut.clk)
    assert int(dut.rebases_total.value) == pre_rebases + 1, (
        f"rebases_total={int(dut.rebases_total.value)}, expected "
        f"{pre_rebases + 1} after one OOW ADD"
    )
    assert int(dut.events_in.value) == pre_events + 1, (
        f"events_in={int(dut.events_in.value)}, expected {pre_events + 1} "
        "after the rebased ADD retires (F.2 §4 squash-and-retry)"
    )
    assert int(dut.tob_deltas_out.value) == pre_deltas + 1, (
        f"tob_deltas_out={int(dut.tob_deltas_out.value)}, expected "
        f"{pre_deltas + 1} — the rebased ADD should emit a new-best delta"
    )


@cocotb.test()
async def test_stale_delete_silent_drop_via_per_sym_state(dut):
    """Same shape as the existing smoke test_stale_delete_silent_drops, but
    rebuilt against the new per_sym_state path. ADD at epoch=0, bump the
    epoch via dbg_epoch_bump (which now writes pss as a rebase on sym=0),
    DELETE the order — d3_stale fires because the per-sym epoch (= 1)
    no longer matches the order's ins_epoch (= 0)."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.dbg_epoch_bump.value = 0
    dut.m_tready.value = 1

    # ADD a single in-window order on sym=AAPL.
    ev_add = _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM,
        price=10010, shares=10, order_id=4242, ingress_ts=0,
    )
    await _book.push_event(dut, ev_add)
    deltas = await _book.collect_deltas(dut, n=1, max_cycles=20)
    assert len(deltas) == 1

    # Bump per-sym epoch via the dbg backdoor (pss rebase on sym=0).
    dut.dbg_epoch_bump.value = 1
    await RisingEdge(dut.clk)
    dut.dbg_epoch_bump.value = 0
    await RisingEdge(dut.clk)

    pre_stale = int(dut.stale_drops.value)
    pre_freed = int(dut.pool_leaks_freed.value)

    # DELETE the order_id=4242 — d3_stale fires (ins_epoch=0 ≠ pss_epoch=1).
    ev_del = _book.pack_book_event(
        ev_type=EV_DELETE, side=0, symbol_id=SYM,
        price=0, shares=0, order_id=4242, ingress_ts=10,
    )
    await _book.push_event(dut, ev_del)
    # The stale DELETE must NOT produce a tob_delta.
    dut.m_tready.value = 1
    for _ in range(20):
        await RisingEdge(dut.clk)
        assert int(dut.m_tvalid.value) == 0, "stale DELETE must not emit a tob_delta"
    assert int(dut.stale_drops.value) - pre_stale == 1
    assert int(dut.pool_leaks_freed.value) - pre_freed == 1


@cocotb.test()
async def test_rebase_isolation_backdoor(dut):
    """A rebase on sym=0 (via dbg backdoor) does NOT bump epoch on any
    other symbol. Backdoor-inspect the per_sym_state epoch_reg array
    directly — read2_sym is RTL-driven from d3_pl_q.sym_idx so cocotb
    cannot use it as a probe; the regfile itself is exposed under
    --public-flat-rw."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.dbg_epoch_bump.value = 0
    # Bump epoch on sym=0 via dbg backdoor (pss rebase write).
    dut.dbg_epoch_bump.value = 1
    await RisingEdge(dut.clk)
    dut.dbg_epoch_bump.value = 0
    await RisingEdge(dut.clk)
    # Probe via the backdoor: epoch_reg[0]=1, every other entry=0.
    epoch0 = int(dut.u_pss.epoch_reg[0].value)
    epoch1 = int(dut.u_pss.epoch_reg[1].value)
    epoch7 = int(dut.u_pss.epoch_reg[7].value)
    assert epoch0 == 1, f"sym=0 epoch should be 1 after rebase, got {epoch0}"
    assert epoch1 == 0, f"sym=1 epoch should be 0 (isolated), got {epoch1}"
    assert epoch7 == 0, f"sym=7 epoch should be 0 (isolated), got {epoch7}"
