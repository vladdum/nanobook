"""Cycle-accurate TB for lob_core.

Per spec docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
§6 (cycle targets table, post-2026-05-11 amendment):
  - ADD: 4 cycles (input handshake edge -> m_tvalid first asserts)
  - DELETE: 6 cycles, hash first-probe hit (input handshake edge -> events_in
    bumps; 1-cycle index register + 1-cycle URAM read + 4-cycle downstream
    pipeline complete in 6 cycles internally; was 5 pre-amendment §3.6)
  - Steady-state throughput: 1 event / 2 cycles (back-to-back distinct-price
    ADDs; bounded by 2-cycle hash latency, §3.6; was 1/cycle pre-amendment)
  - Filtered events: 1 cycle, never enter ADD/DEL paths
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


# Per-test clock with prior-task kill. Each @cocotb.test() runs in the SAME
# sim invocation against the SAME DUT instance, so without this guard every
# test would spawn a fresh Clock(dut.clk, 4, "ns").start() coroutine AND the
# prior tests' generators would still be alive — by test 4, four concurrent
# generators would race on dut.clk and the throughput test's cycle bounds
# would break (observed: 64/100 events retired instead of 100 when run after
# tests 1-3). Killing the prior task before starting a new one keeps exactly
# one clock generator active per test.
_clock_task = None


def _start_clock(dut) -> None:
    global _clock_task
    if _clock_task is not None:
        _clock_task.kill()
    _clock_task = cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())


# M06 E.2: lob_core now filters via sym_idx_lut (NOT SYMBOL_FILTER_ID). Use a
# stock_locate that's in the picked-100 LUT — locate=5754 (AAPL) maps to
# sym_idx=0 in lob_core_sym_pkg::STOCK_LOCATE_TO_SYM_IDX.
SYM = 5754

# event_type_e mirror (book_event_pkg.sv): A=0, X=1 (cancel), D=2, E=3, ExecPx=4.
EV_ADD = 0
EV_CANCEL = 1
EV_DELETE = 2
EV_EXEC = 3


async def _wait_handshake(dut) -> None:
    """Drive s_tvalid=1, await the rising edge on which s_tready was high
    (= input captured), then deassert s_tvalid."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_tready.value):
            break
    dut.s_tvalid.value = 0


async def _drive_event_count_cycles_until_delta(dut, ev_word: int, max_cycles: int = 16) -> int:
    """Drive one event; count rising edges from the handshake-edge until
    m_tvalid asserts. The check is performed BEFORE the next edge, so n=k
    means m_tvalid first appeared k cycles after the handshake edge."""
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
    raise TimeoutError("no tob_delta within max_cycles")


@cocotb.test()
async def test_add_4_cycles(dut):
    """ADD pipeline: input handshake -> m_tvalid in 4 cycles (spec §6)."""
    _start_clock(dut)
    await _book.reset(dut)
    ev = _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM,
        price=10000, shares=100, order_id=1, ingress_ts=0,
    )
    n = await _drive_event_count_cycles_until_delta(dut, ev)
    assert n == 4, f"ADD took {n} cycles, expected 4"


@cocotb.test()
async def test_delete_6_cycles_first_probe(dut):
    """DELETE on non-best order: events_in bumps 6 cycles after handshake.

    Post-2026-05-11 amendment (spec §3.6): registered URAM read in
    order_id_hash adds 1 cycle to the hash lookup, so the DELETE pipeline
    runs handshake -> events_in in 6 cycles (was 5).

    Non-best DELETE emits no tob_delta (best stays unchanged) so we measure
    completion via the events_in counter, which the orchestrator bumps at
    the END of the pipeline (NOT at input handshake)."""
    _start_clock(dut)
    await _book.reset(dut)
    # Two ADDs at the same price so the DELETE has a non-best target.
    for oid in (1, 2):
        ev = _book.pack_book_event(
            ev_type=EV_ADD, side=0, symbol_id=SYM,
            price=10000, shares=100, order_id=oid, ingress_ts=0,
        )
        await _book.push_event(dut, ev)
    # Drain pipeline so the two ADDs fully complete (events_in == 2,
    # tob delta consumed). 12 cycles is comfortably > pipeline depth.
    dut.m_tready.value = 1
    for _ in range(12):
        await RisingEdge(dut.clk)
    # Now drive the DELETE on order_id=2 (the non-best — same price, not
    # the head). Expect events_in to bump exactly 6 cycles after handshake.
    delete_ev = _book.pack_book_event(
        ev_type=EV_DELETE, side=0, symbol_id=SYM, price=10000, shares=100,
        order_id=2, ingress_ts=0,
    )
    initial = int(dut.events_in.value)
    dut.s_tdata.value = delete_ev
    dut.s_tvalid.value = 1
    dut.s_tlast.value = 1
    await _wait_handshake(dut)
    n = 0
    while int(dut.events_in.value) == initial:
        await RisingEdge(dut.clk)
        n += 1
        if n > 12:
            raise TimeoutError(f"events_in never bumped (still {initial})")
    assert n == 6, f"DELETE took {n} cycles, expected 6 (post-2026-05-11)"


@cocotb.test()
async def test_filtered_event_dropped_no_delta(dut):
    """Wrong-symbol event: events_filtered++, never any tob_delta."""
    _start_clock(dut)
    await _book.reset(dut)
    ev = _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM + 1,   # wrong symbol
        price=10000, shares=100, order_id=99, ingress_ts=0,
    )
    initial_filt = int(dut.events_filtered.value)
    dut.m_tready.value = 1
    await _book.push_event(dut, ev)
    # events_filtered should bump within 1-2 cycles of the handshake.
    for _ in range(3):
        await RisingEdge(dut.clk)
        if int(dut.events_filtered.value) == initial_filt + 1:
            break
    assert int(dut.events_filtered.value) == initial_filt + 1, \
        f"events_filtered={int(dut.events_filtered.value)}, expected {initial_filt + 1}"
    # No delta should ever appear over the next 16 cycles.
    for _ in range(16):
        await RisingEdge(dut.clk)
        assert int(dut.m_tvalid.value) == 0, "filtered event must not emit a tob_delta"


@cocotb.test()
async def test_steady_state_one_event_per_two_cycles(dut):
    """100 back-to-back distinct-price ADDs retire in 2*N + drain cycles.

    Post-2026-05-11 amendment (spec §3.6): hash 2-cycle latency means a new
    ADD can be accepted only every other cycle (orchestrator's hash_busy
    stall extended from DEL-class only to also gate ADD). 100 events
    therefore retire in 2*N_EVENTS + drain (pipeline-depth) cycles, not
    N_EVENTS + drain as pre-amendment.

    Additionally asserts that the hash_busy stall actually fires — at least
    one cycle saw s_tready=0 while s_tvalid=1 (a regression on the stall
    extension would let all 100 ADDs through in <2N cycles, which still
    passes a generous bound but breaks the throughput contract)."""
    _start_clock(dut)
    await _book.reset(dut)
    initial = int(dut.events_in.value)
    dut.m_tready.value = 1

    N_EVENTS = 100
    # Pre-amendment expectation was N_EVENTS + drain. Post-amendment:
    # 2*N_EVENTS + drain (hash is busy every other cycle).
    drain = 16  # comfortably > pipeline depth
    max_cycles = 2 * N_EVENTS + drain

    observed_stall_cycles = 0
    elapsed = 0
    for i in range(N_EVENTS):
        ev = _book.pack_book_event(
            ev_type=EV_ADD, side=0, symbol_id=SYM,
            price=10000 + i, shares=100, order_id=1000 + i, ingress_ts=0,
        )
        dut.s_tdata.value = ev
        dut.s_tvalid.value = 1
        dut.s_tlast.value = 1
        # Wait until this event handshakes; count cycles where we held
        # s_tvalid high but s_tready was low (= hash_busy stall on ADD).
        while True:
            await RisingEdge(dut.clk)
            elapsed += 1
            if int(dut.s_tready.value):
                break
            observed_stall_cycles += 1
            if elapsed >= max_cycles:
                raise TimeoutError(
                    f"event {i} never handshook within {max_cycles} cycles"
                )
    dut.s_tvalid.value = 0
    # Allow any remaining in-flight events to retire.
    for _ in range(drain):
        await RisingEdge(dut.clk)
    events_in_q_final = int(dut.events_in.value) - initial

    assert events_in_q_final == N_EVENTS, (
        f"only {events_in_q_final} of {N_EVENTS} events retired"
    )
    assert observed_stall_cycles >= N_EVENTS - 1, (
        f"expected >= {N_EVENTS-1} hash_busy stall cycles, got "
        f"{observed_stall_cycles}; the orchestrator's ADD stall may be missing"
    )
