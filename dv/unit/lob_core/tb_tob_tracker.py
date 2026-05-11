"""Tests for hw/ip/lob_core/tob_tracker.sv.

Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 19.
Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
      §3.1, §3.2 step 4, §3.3 step 5, §5.1.

The bitmap is parametrised down to WINDOW_SIZE_TICKS=64 here so the
Verilator build is tractable. WINDOW_BASE_TICK=10000 matches the
-GWINDOW_BASE_TICK in Makefile.tob_tracker.

Timing pattern (Cocotb 2.0 + Verilator 5.046):
  cocotb defers signal writes — `dut.signal.value = X` is queued and
  only takes effect at the next simulator step. As a result, after
  driving a request strobe the RTL needs an extra rising edge before
  the registered output reflects the response. The `_drive_op_and_wait`
  helper drives the strobe, polls `m_tvalid` over a few cycles, and
  returns the captured TobDelta. This mirrors the
  dv/unit/itch_decoder polling style.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


WINDOW_BASE = 10000
WINDOW_SIZE = 64


async def _reset(dut, cycles=4):
    dut.rstn.value = 0
    dut.set_bit_req.value = 0
    dut.clr_bit_req.value = 0
    dut.update_size_req.value = 0
    dut.op_side.value = 0
    dut.op_price.value = 0
    dut.op_size.value = 0
    dut.op_reason.value = 0
    dut.cur_ts.value = 0
    dut.ingress_ts.value = 0
    dut.m_tready.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


# TOB reason codes (mirror book_event_pkg::tob_reason_e).
_REASON_ADD    = 0
_REASON_CANCEL = 1
_REASON_DELETE = 2
_REASON_EXEC   = 3


async def _drive_strobe_one_cycle(dut, *, set_req=0, clr_req=0, upd_req=0,
                                  side=0, price=0, size=0, reason=0):
    """Drive one of {set,clr,upd} req for exactly one rising edge, then
    deassert. Wait one extra edge for cocotb's deferred write to land."""
    dut.op_side.value = side
    dut.op_price.value = price
    dut.op_size.value = size
    dut.op_reason.value = reason
    dut.set_bit_req.value = set_req
    dut.clr_bit_req.value = clr_req
    dut.update_size_req.value = upd_req
    # First edge: cocotb queues writes; RTL may not yet see the strobe.
    await RisingEdge(dut.clk)
    # Second edge: RTL has now observed the strobe and registered its
    # response (m_tvalid_q rises).
    await RisingEdge(dut.clk)
    # Deassert and let the bus settle so subsequent calls don't see a
    # stale strobe.
    dut.set_bit_req.value = 0
    dut.clr_bit_req.value = 0
    dut.update_size_req.value = 0
    await RisingEdge(dut.clk)


async def _set_bit(dut, side, price, size, reason=_REASON_ADD):
    await _drive_strobe_one_cycle(dut, set_req=1, side=side,
                                  price=price, size=size, reason=reason)


async def _clr_bit(dut, side, price, reason=_REASON_DELETE):
    await _drive_strobe_one_cycle(dut, clr_req=1, side=side, price=price,
                                  reason=reason)


def _expected_symbol_id(dut) -> int:
    """Resolve SYMBOL_FILTER_ID parameter from the dut; cocotb 2.0
    exposes parameter overrides directly on the handle. Falls back
    to the package default (5754, see lob_core_params_pkg.sv) if the
    simulator did not surface the parameter."""
    try:
        return int(dut.SYMBOL_FILTER_ID.value)
    except (AttributeError, ValueError):
        return 5754


@cocotb.test()
async def test_first_set_emits_delta(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Drive set_req only. Capture m_tvalid + m_tdata while the strobe
    # is still asserted (m_tvalid rises on the second edge inside
    # _drive_strobe_one_cycle, which is ABOVE — so we read at the
    # third edge where m_tvalid is still 1 and the RTL has just
    # finished updating delta_q).
    dut.op_side.value = 0
    dut.op_price.value = WINDOW_BASE + 5
    dut.op_size.value = 100
    dut.op_reason.value = _REASON_ADD
    dut.set_bit_req.value = 1
    await RisingEdge(dut.clk)  # cocotb write queue
    await RisingEdge(dut.clk)  # RTL captures strobe; m_tvalid_q -> 1
    assert int(dut.m_tvalid.value) == 1, "expected m_tvalid high after first ADD"
    delta = _book.unpack_tob_delta(int(dut.m_tdata.value))
    assert delta.symbol_id == _expected_symbol_id(dut), (
        f"symbol_id={delta.symbol_id} expected={_expected_symbol_id(dut)}"
    )
    assert delta.side == 0
    assert delta.new_best_price == WINDOW_BASE + 5
    assert delta.new_best_size == 100
    assert delta.reason == 0  # TOB_REASON_ADD
    dut.set_bit_req.value = 0


@cocotb.test()
async def test_better_price_updates_best(dut):
    """For bids, higher price = better."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _set_bit(dut, side=0, price=WINDOW_BASE + 5, size=100)
    await _set_bit(dut, side=0, price=WINDOW_BASE + 10, size=50)
    delta = _book.unpack_tob_delta(int(dut.m_tdata.value))
    assert delta.new_best_price == WINDOW_BASE + 10, (
        f"new_best_price={delta.new_best_price} expected={WINDOW_BASE + 10}"
    )
    assert delta.new_best_size == 50
    assert delta.side == 0


@cocotb.test()
async def test_clear_best_recomputes_via_clz(dut):
    """When the current best level is cleared AND a new best exists,
    tob_tracker no longer emits a placeholder delta. It pulses
    pending_clr_valid_o for one cycle with the new best's coordinates
    so lob_core can fetch the size and drive update_size_req. The
    full delta is then emitted by tob_tracker's update_size branch on
    the cycle lob_core supplies the size — see lob_core.sv."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _set_bit(dut, 0, WINDOW_BASE + 5, 100)
    await _set_bit(dut, 0, WINDOW_BASE + 10, 50)
    # Drive clr_bit and poll pending_clr_valid_o over a small window.
    # The pulse is registered (1 cycle wide) and may surface on edge 2
    # or edge 3 depending on cocotb deferred-write timing under
    # Verilator. Capture the first cycle it goes high.
    dut.op_side.value     = 0
    dut.op_price.value    = WINDOW_BASE + 10
    dut.op_reason.value   = _REASON_DELETE
    dut.clr_bit_req.value = 1
    pending_seen = False
    captured = {}
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.pending_clr_valid_o.value) and not pending_seen:
            pending_seen = True
            captured = {
                "price": int(dut.pending_clr_price_o.value),
                "side":  int(dut.pending_clr_side_o.value),
                "reason": int(dut.pending_clr_reason_o.value),
            }
            dut.clr_bit_req.value = 0   # deassert once captured
            break
    dut.clr_bit_req.value = 0
    assert pending_seen, (
        "expected pending_clr_valid_o pulse on clr-empty-with-new-best"
    )
    assert captured["price"] == WINDOW_BASE + 5, captured
    assert captured["side"] == 0, captured
    assert captured["reason"] == _REASON_DELETE, captured


@cocotb.test()
async def test_clear_only_active_emits_zero_size(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    await _set_bit(dut, 1, WINDOW_BASE + 7, 200)
    await _clr_bit(dut, 1, WINDOW_BASE + 7)
    delta = _book.unpack_tob_delta(int(dut.m_tdata.value))
    assert delta.new_best_size == 0, (
        f"new_best_size={delta.new_best_size} expected=0"
    )
    assert delta.new_best_price == 0
    assert delta.side == 1
    assert delta.reason == 2  # TOB_REASON_DELETE
