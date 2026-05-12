"""M06 cycle-accurate TB.

Plan: docs/superpowers/plans/2026-05-12-nanobook-m06-multi-symbol-sliding-window.md
      Task G.1.

Asserts the cycle counts that the M06 D.1–D.3 CLZ pipeline introduces on top
of the M05 baseline (which is regression-covered by tb_lob_core_cycles.py).
The two new measurements here are:

  1. DELETE on best-with-another-level-remaining — CLZ fires; handshake →
     tob_deltas_out bump should land CLZ_LATENCY=1 cycles later than the
     side-empty direct-emit path because of the s1+s2 pipeline plus the
     1-cycle internal kick-delay.

  2. DELETE on best-with-side-going-empty — no CLZ; direct emit. This is
     the baseline number against which (1) is compared.

The cross-symbol / rebase / stale-via-sym_idx_lut tests from Phase G in the
plan are deferred until Phases E and F land — they need sym_idx_lut.sv and
per_sym_state.sv in the source list.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


# M06 E.2: lob_core now filters via sym_idx_lut (NOT SYMBOL_FILTER_ID). Use a
# stock_locate that's in the picked-100 LUT — locate=5754 (AAPL) maps to
# sym_idx=0 in lob_core_sym_pkg::STOCK_LOCATE_TO_SYM_IDX.
SYM = 5754

EV_ADD     = 0
EV_DELETE  = 2

# Match Makefile.lob_core_cycles_m06 -GWINDOW_BASE_TICK=10000.
PRICE_BASE = 10000


# Per-test clock with prior-task kill (same pattern as tb_lob_core_cycles).
_clock_task = None


def _start_clock(dut) -> None:
    global _clock_task
    if _clock_task is not None:
        _clock_task.kill()
    _clock_task = cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())


async def _wait_handshake(dut) -> None:
    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_tready.value):
            break
    dut.s_tvalid.value = 0


async def _drive_event_count_cycles_until_delta(dut, ev_word: int, max_cycles: int = 40) -> int:
    """Drive one event; count rising edges from the handshake edge until
    m_tvalid first asserts. Mirrors tb_lob_core_cycles.py's helper so M05
    and M06 measurements are directly comparable."""
    dut.s_tdata.value = ev_word
    dut.s_tvalid.value = 1
    dut.s_tlast.value = 1
    dut.m_tready.value = 1
    await _wait_handshake(dut)
    n = 0
    for _ in range(max_cycles):
        if int(dut.m_tvalid.value):
            return n
        await RisingEdge(dut.clk)
        n += 1
    raise TimeoutError(f"m_tvalid never asserted within {max_cycles} cycles")


def _add_event(price: int, order_id: int) -> int:
    return _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM,
        price=price, shares=100, order_id=order_id, ingress_ts=0,
    )


def _del_event(price: int, order_id: int) -> int:
    return _book.pack_book_event(
        ev_type=EV_DELETE, side=0, symbol_id=SYM,
        price=price, shares=0, order_id=order_id, ingress_ts=0,
    )


async def _push_and_drain(dut, ev_word: int, drain_cycles: int = 16) -> None:
    """Push one event, drain the pipeline so the next test starts clean."""
    dut.m_tready.value = 1
    await _book.push_event(dut, ev_word)
    for _ in range(drain_cycles):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_add_5_cycles_regression(dut):
    """Regression: ADD baseline post-2026-05-13 — 5 cycles from handshake
    to m_tvalid (the first ADD emits a tob_delta because best changes).

    Was 4 cycles pre-2026-05-13. Registering price_ladder.levels (§3.7
    amendment) adds one cycle to the ladder output, shifting m_tvalid +1.
    """
    _start_clock(dut)
    await _book.reset(dut)
    n = await _drive_event_count_cycles_until_delta(dut, _add_event(PRICE_BASE + 5, 1))
    assert n == 5, f"ADD took {n} cycles, expected 5"


@cocotb.test()
async def test_delete_side_empty_direct_emit_m06(dut):
    """DELETE the only order — side empties → tob_tracker's clr branch emits
    the zero-size delta DIRECTLY (no CLZ). Measures the baseline DELETE-to-
    emit latency.

    Post-2026-05-13 amendments: 8 cycles (was 6 pre-amendments). The two
    cycles come from:
      - +1 from hash payload registration (§3.6 amendment): hash_op_done
        is one cycle later, so d2 of the orchestrator's DEL pipeline fires
        one cycle later. This shifts the entire downstream chain by +1.
      - +1 from price_ladder.levels URAM registration (§3.7 amendment):
        ladder_del_req → level_evt_valid path is now 2 cycles (was 1).
        tob_tracker's clr branch sees level_now_empty one cycle later, and
        m_tvalid_q surfaces another cycle after that.
    """
    _start_clock(dut)
    await _book.reset(dut)
    # Seed: one bid at PRICE_BASE+5.
    await _push_and_drain(dut, _add_event(PRICE_BASE + 5, 1))
    # DELETE it. Side empties. tob_tracker direct emits side-empty delta.
    n = await _drive_event_count_cycles_until_delta(dut, _del_event(PRICE_BASE + 5, 1))
    assert n == 8, f"DELETE-side-empty took {n} cycles, expected 8"


@cocotb.test()
async def test_delete_clz_driven_emit_m06(dut):
    """DELETE the best on a side that has another level remaining → CLZ
    fires → handshake-to-tob_delta-emit is the baseline plus the CLZ
    pipeline cost (1 cycle internal kick delay + CLZ s1 + CLZ s2 + the
    clr_fu1/clr_fu2 ladder-read pipeline that re-fires update_size_req
    with the correct size from price_ladder).

    Post-2026-05-13 amendments: 14 cycles (was 12 pre-amendments). The two
    extra cycles come from the same +1 hash payload + +1 ladder URAM read
    contributions as test_delete_side_empty_direct_emit_m06.

    The DELTA between this and test_delete_side_empty_direct_emit_m06's 8
    cycles (= 6) is what the cycle TB exposes as the CLZ_LATENCY
    contribution — this is INVARIANT under the 2026-05-13 amendments
    because both tests pay the same +2 cycle cost. The cross-check test
    `test_clz_latency_extra_cycles_match_param` asserts the delta is
    exactly CLZ_LATENCY + 5."""
    _start_clock(dut)
    await _book.reset(dut)
    # Seed: two bids, one at PRICE_BASE+5 (non-best), one at PRICE_BASE+10 (best).
    await _push_and_drain(dut, _add_event(PRICE_BASE + 5, 1))
    await _push_and_drain(dut, _add_event(PRICE_BASE + 10, 2))
    # DELETE the best (order_id=2). CLZ kicks; finds PRICE_BASE+5 as the new
    # best; lob_core fetches the new best's size via ladder_read; tob_tracker
    # update_size branch emits the delta.
    n = await _drive_event_count_cycles_until_delta(dut, _del_event(PRICE_BASE + 10, 2))
    assert n == 14, f"DELETE-CLZ took {n} cycles, expected 14 (CLZ_LATENCY=1)"


@cocotb.test()
async def test_clz_latency_extra_cycles_match_param(dut):
    """Drive the DELETE-CLZ and DELETE-side-empty scenarios back-to-back
    and assert that the cycle delta is exactly 6 = CLZ_LATENCY + 5 (the +5
    is the fixed orchestrator overhead: 1 cycle internal kick delay + 1
    cycle CLZ s1 latch + 2 cycles clr_fu1/clr_fu2 + 1 cycle update_size
    register; CLZ_LATENCY scales the mid-stage register count between s1
    and s2). A regression in either the CLZ pipeline depth or the clr_fu
    pipeline trips this assertion.

    Falls back to the package default CLZ_LATENCY=1 if Verilator did not
    surface the parameter on the DUT handle."""
    _start_clock(dut)
    # Measurement 1: DELETE-side-empty baseline.
    await _book.reset(dut)
    await _push_and_drain(dut, _add_event(PRICE_BASE + 5, 1))
    n_empty = await _drive_event_count_cycles_until_delta(dut, _del_event(PRICE_BASE + 5, 1))
    # Measurement 2: DELETE-CLZ.
    await _book.reset(dut)
    await _push_and_drain(dut, _add_event(PRICE_BASE + 5, 1))
    await _push_and_drain(dut, _add_event(PRICE_BASE + 10, 2))
    n_clz   = await _drive_event_count_cycles_until_delta(dut, _del_event(PRICE_BASE + 10, 2))
    try:
        clz_lat = int(dut.lob_core_params_pkg.CLZ_LATENCY.value)
    except AttributeError:
        clz_lat = 1
    expected_extra = clz_lat + 5
    assert n_clz - n_empty == expected_extra, (
        f"CLZ-vs-side-empty delta = {n_clz - n_empty}; expected "
        f"{expected_extra} = CLZ_LATENCY({clz_lat}) + 5 (fixed overhead). "
        f"Raw measurements: side-empty={n_empty}, CLZ-driven={n_clz}"
    )
