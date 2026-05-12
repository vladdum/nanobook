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
    dut.op_sym_idx.value = 0
    dut.cur_ts.value = 0
    dut.ingress_ts.value = 0
    dut.m_tready.value = 1
    dut.clz_kick.value = 0
    dut.clz_kick_sym.value = 0
    dut.clz_kick_side.value = 0
    # Sim-only: URAM-backed slice_bitmap_ram does not have a synchronous
    # reset in real silicon (the slice_present_q='0 invariant on rstn
    # makes its initial contents unobservable). Across cocotb test
    # functions, however, the array retains bits from the previous test
    # and the D.3 CLZ-driven emit path reads it directly — bypassing
    # bid_bitmap_q/ask_bitmap_q's reset. Zero it explicitly here so each
    # test starts with a clean URAM.
    if hasattr(dut, 'slice_bitmap_ram'):
        try:
            n_entries = len(dut.slice_bitmap_ram)
        except TypeError:
            n_entries = 0
        for i in range(n_entries):
            dut.slice_bitmap_ram[i].value = 0
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
                                  side=0, price=0, size=0, reason=0,
                                  sym_idx=0):
    """Drive one of {set,clr,upd} req for exactly one rising edge, then
    deassert. Wait one extra edge for cocotb's deferred write to land."""
    dut.op_side.value = side
    dut.op_price.value = price
    dut.op_size.value = size
    dut.op_reason.value = reason
    dut.op_sym_idx.value = sym_idx
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


async def _set_bit(dut, side, price, size, reason=_REASON_ADD, sym_idx=0):
    await _drive_strobe_one_cycle(dut, set_req=1, side=side,
                                  price=price, size=size, reason=reason,
                                  sym_idx=sym_idx)


async def _clr_bit(dut, side, price, reason=_REASON_DELETE, sym_idx=0):
    await _drive_strobe_one_cycle(dut, clr_req=1, side=side, price=price,
                                  reason=reason, sym_idx=sym_idx)


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


# ---------------------------------------------------------------------------
# M06 helpers and tests — per-symbol best register isolation
# ---------------------------------------------------------------------------

async def _set_best_m06(dut, sym_idx, side, price, size):
    """Issue a set_bit_req that causes tob_tracker to update best for
    (sym_idx, side) to (price, size). Drives op_sym_idx before the strobe."""
    await _drive_strobe_one_cycle(dut, set_req=1, side=side,
                                  price=price, size=size,
                                  reason=_REASON_ADD, sym_idx=sym_idx)


async def _read_best_m06(dut, sym_idx, side) -> dict:
    """Returns {tick, size, valid} for the (sym_idx, side) best register
    via backdoor read of the per-sym arrays."""
    if side == 0:
        return {
            "tick":  int(dut.best_bid_tick_q[sym_idx].value),
            "size":  int(dut.best_bid_size_q[sym_idx].value),
            "valid": int(dut.best_bid_valid_q[sym_idx].value),
        }
    else:
        return {
            "tick":  int(dut.best_ask_tick_q[sym_idx].value),
            "size":  int(dut.best_ask_size_q[sym_idx].value),
            "valid": int(dut.best_ask_valid_q[sym_idx].value),
        }


@cocotb.test()
async def test_per_sym_best_isolation_m06(dut):
    """tob_tracker tracks per-symbol best independently. Updating best on
    sym=0 does not perturb sym=1's best register."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # Update best bid for sym=0 to (price=WINDOW_BASE+100, size=10)
    await _set_best_m06(dut, sym_idx=0, side=0,
                        price=WINDOW_BASE + 100, size=10)
    # Update best bid for sym=1 to (price=WINDOW_BASE+200, size=20)
    # Note: sym=1 uses a different tick offset — bitmaps are shared in Phase C
    # so we use an offset that fits within WINDOW_SIZE=64
    await _set_best_m06(dut, sym_idx=1, side=0,
                        price=WINDOW_BASE + 20, size=20)
    # Wait an extra cycle for registers to settle
    await RisingEdge(dut.clk)
    # Verify sym=0 register independently
    b0 = await _read_best_m06(dut, sym_idx=0, side=0)
    assert b0["tick"] == WINDOW_BASE + 100, (
        f"sym=0 tick = {b0['tick']}, expected {WINDOW_BASE + 100}"
    )
    assert b0["size"] == 10, f"sym=0 size = {b0['size']}, expected 10"
    assert b0["valid"] == 1, "sym=0 valid should be 1"
    # Verify sym=1 register independently
    b1 = await _read_best_m06(dut, sym_idx=1, side=0)
    assert b1["tick"] == WINDOW_BASE + 20, (
        f"sym=1 tick = {b1['tick']}, expected {WINDOW_BASE + 20}"
    )
    assert b1["size"] == 20, f"sym=1 size = {b1['size']}, expected 20"
    assert b1["valid"] == 1, "sym=1 valid should be 1"
    # Verify sym=0 was not modified by sym=1's update
    assert b0["tick"] != b1["tick"], (
        "sym=0 and sym=1 best ticks must differ (isolation violated)"
    )


async def _set_bitmap_bit_m06(dut, sym_idx, side, tick, value):
    """Drive set_bit_req or clr_bit_req for (sym_idx, side, tick).
    Uses _drive_strobe_one_cycle pattern for consistent timing."""
    base = WINDOW_BASE
    price = base + tick
    if value:
        await _drive_strobe_one_cycle(dut, set_req=1, side=side,
                                      price=price, size=100,
                                      reason=_REASON_ADD, sym_idx=sym_idx)
    else:
        await _drive_strobe_one_cycle(dut, clr_req=1, side=side,
                                      price=price, size=0,
                                      reason=_REASON_DELETE, sym_idx=sym_idx)


@cocotb.test()
async def test_slice_present_tracks_slice_bitmap_population_m06(dut):
    """Setting any bit in slice k sets slice_present_q[sym][side][k].
    Clearing the last bit in a slice clears slice_present_q."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # TB's WINDOW_SIZE_TICKS = 64 -> N_SLICES = 1. So tick=0..63 is slice 0.
    # If the TB uses a larger window, pick slice 1 (ticks 64..127).
    win_sz = WINDOW_SIZE
    n_slices = win_sz // 64
    # Use side=1 (ask) throughout this test.  The preceding test
    # (test_per_sym_best_isolation_m06) only drives side=0, so the ask-side
    # slice_bitmap_ram entries are guaranteed to be zero after reset.
    # (URAM is not cleared on reset, but ask-side entries are untouched.)
    if n_slices < 2:
        # Single-slice config: verify set/clear toggles slice_present_q[0][1][0]
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=1, tick=10, value=1)
        # _drive_strobe_one_cycle already waits 3 edges; one extra edge ensures
        # the NBA assignment has propagated through Verilator's delta cycle.
        await RisingEdge(dut.clk)
        sp = int(dut.slice_present_q[0][1].value)
        assert sp & 1, f"slice 0 should be present after set, got slice_present_q={sp:#x}"
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=1, tick=10, value=0)
        await RisingEdge(dut.clk)
        sp = int(dut.slice_present_q[0][1].value)
        assert (sp & 1) == 0, (
            f"slice 0 should be clear after the last bit clears, got slice_present_q={sp:#x}"
        )
    else:
        # Multi-slice config: set tick 100 = slice 1 (bits 64-127) bit 36
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=1, tick=100, value=1)
        await RisingEdge(dut.clk)
        sp = int(dut.slice_present_q[0][1].value)
        assert sp & (1 << 1), f"slice 1 should be present, got slice_present_q={sp:#x}"
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=1, tick=100, value=0)
        await RisingEdge(dut.clk)
        sp = int(dut.slice_present_q[0][1].value)
        assert (sp & (1 << 1)) == 0, (
            f"slice 1 should be empty after the last bit clears, got slice_present_q={sp:#x}"
        )


# ---------------------------------------------------------------------------
# M06 D.2 — 2-stage 64×64 pipelined CLZ tests
# ---------------------------------------------------------------------------

async def _kick_clz_m06(dut, sym_idx, side):
    """Issue a single-cycle CLZ kick for (sym_idx, side)."""
    dut.clz_kick_sym.value = sym_idx
    dut.clz_kick_side.value = side
    dut.clz_kick.value = 1
    await RisingEdge(dut.clk)
    dut.clz_kick.value = 0


@cocotb.test()
async def test_clz_finds_highest_bid_tick_m06(dut):
    """Set bits at ticks {20, 30, 50} on sym=0, side=0 (bid). CLZ should return tick=50 (highest)."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    # WINDOW_SIZE=64 in TB: ticks 20, 30, 50 all fit in slice 0.
    for t in (20, 30, 50):
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=0, tick=t, value=1)
    await _kick_clz_m06(dut, sym_idx=0, side=0)
    for _ in range(6):
        await RisingEdge(dut.clk)
        if int(dut.clz_result_valid.value):
            assert int(dut.clz_result_tick.value) == 50, (
                f"expected tick=50, got {int(dut.clz_result_tick.value)}"
            )
            return
    assert False, "CLZ never produced a result"


@cocotb.test()
async def test_clz_finds_lowest_ask_tick_m06(dut):
    """Set bits at ticks {20, 30, 50} on sym=0, side=1 (ask). CLZ should return tick=20 (lowest)."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    for t in (20, 30, 50):
        await _set_bitmap_bit_m06(dut, sym_idx=0, side=1, tick=t, value=1)
    await _kick_clz_m06(dut, sym_idx=0, side=1)
    for _ in range(6):
        await RisingEdge(dut.clk)
        if int(dut.clz_result_valid.value):
            assert int(dut.clz_result_tick.value) == 20, (
                f"expected tick=20, got {int(dut.clz_result_tick.value)}"
            )
            return
    assert False, "CLZ never produced a result"


# ---------------------------------------------------------------------------
# M06 D.3 — CLZ-driven emit path on clr-empties-best
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_emit_after_level_empties_uses_clz_for_new_best_m06(dut):
    """ADD ticks {10, 25, 40} on sym=0 bid. DELETE 40 (the current best).
    The new best must be discovered via the 2-stage CLZ (not the M05 flat
    encoder) and surface on pending_clr_valid_o with price=WINDOW_BASE+25.

    The pulse arrives later than the M05 flat encoder produced it (CLZ adds
    ~2 cycles of pipeline latency), so the polling window is wider than
    test_clear_best_recomputes_via_clz's."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    for tick, size in ((10, 100), (25, 50), (40, 30)):
        await _set_bit(dut, side=0, price=WINDOW_BASE + tick, size=size)
    dut.op_side.value     = 0
    dut.op_price.value    = WINDOW_BASE + 40
    dut.op_reason.value   = _REASON_DELETE
    dut.clr_bit_req.value = 1
    pending_seen = False
    captured = {}
    for _ in range(12):
        await RisingEdge(dut.clk)
        if int(dut.pending_clr_valid_o.value) and not pending_seen:
            pending_seen = True
            captured = {
                "price":  int(dut.pending_clr_price_o.value),
                "side":   int(dut.pending_clr_side_o.value),
                "reason": int(dut.pending_clr_reason_o.value),
            }
            dut.clr_bit_req.value = 0
            break
    dut.clr_bit_req.value = 0
    assert pending_seen, (
        "expected pending_clr_valid_o pulse via CLZ within 12 cycles"
    )
    assert captured["price"] == WINDOW_BASE + 25, captured
    assert captured["side"] == 0, captured
    assert captured["reason"] == _REASON_DELETE, captured


@cocotb.test()
async def test_emit_after_level_empties_ask_via_clz_m06(dut):
    """Mirror of the bid-side test for ask: ADD ticks {10, 25, 40} on sym=0
    ask. DELETE 10 (the current best). CLZ must discover tick=25 as the
    new best."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _reset(dut)
    for tick, size in ((10, 100), (25, 50), (40, 30)):
        await _set_bit(dut, side=1, price=WINDOW_BASE + tick, size=size)
    dut.op_side.value     = 1
    dut.op_price.value    = WINDOW_BASE + 10
    dut.op_reason.value   = _REASON_DELETE
    dut.clr_bit_req.value = 1
    pending_seen = False
    captured = {}
    for _ in range(12):
        await RisingEdge(dut.clk)
        if int(dut.pending_clr_valid_o.value) and not pending_seen:
            pending_seen = True
            captured = {
                "price":  int(dut.pending_clr_price_o.value),
                "side":   int(dut.pending_clr_side_o.value),
                "reason": int(dut.pending_clr_reason_o.value),
            }
            dut.clr_bit_req.value = 0
            break
    dut.clr_bit_req.value = 0
    assert pending_seen, "expected pending_clr_valid_o pulse via CLZ within 12 cycles"
    assert captured["price"] == WINDOW_BASE + 25, captured
    assert captured["side"] == 1, captured
    assert captured["reason"] == _REASON_DELETE, captured
