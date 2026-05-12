"""Cycle-accurate TB for lob_core.

Per spec docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md
§6 (cycle targets table, post-2026-05-13 amendment):
  - ADD: 5 cycles (input handshake edge -> m_tvalid first asserts; +1 over
    M05 baseline from registered price_ladder.levels URAM read, §3.7)
  - DELETE: 7 cycles, hash first-probe hit (input handshake edge -> events_in
    bumps; M05 baseline 5 + 1 (hash bucket-index reg, 2026-05-11) + 1
    (hash payload reg, 2026-05-13); was 6 post-2026-05-11)
  - Steady-state throughput: 1 event / 3 cycles (back-to-back distinct-price
    ADDs; bounded by the 3-cycle hash latency post-2026-05-13; was 1/2
    post-2026-05-11, 1/cycle pre-amendment)
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
async def test_add_5_cycles(dut):
    """ADD pipeline: input handshake -> m_tvalid in 5 cycles (spec §6,
    post-2026-05-13 amendment).

    M05 baseline was 4 cycles. Registering the URAM read in
    price_ladder.levels (§3.7 amendment) adds one cycle to the ladder
    output, which moves m_tvalid one cycle later. The hash-side payload
    register also added (§3.6 amendment) does NOT affect ADD because the
    ADD path's m_tvalid is gated on level_evt (from the ladder), not on
    hash_op_done — the hash_insert is fire-and-forget along the ADD path.
    """
    _start_clock(dut)
    await _book.reset(dut)
    ev = _book.pack_book_event(
        ev_type=EV_ADD, side=0, symbol_id=SYM,
        price=10000, shares=100, order_id=1, ingress_ts=0,
    )
    n = await _drive_event_count_cycles_until_delta(dut, ev)
    assert n == 5, f"ADD took {n} cycles, expected 5"


@cocotb.test()
async def test_delete_7_cycles_first_probe(dut):
    """DELETE on non-best order: events_in bumps 7 cycles after handshake.

    Post-2026-05-13 amendment (spec §3.6): registering the hash table_ram
    PAYLOAD (on top of the 2026-05-11 bucket-index reg) adds another cycle
    to the hash lookup. The DELETE pipeline runs handshake -> events_in
    in 7 cycles (was 6 post-2026-05-11, 5 pre-amendment).

    Note: this measurement is events_in-based, so the price_ladder URAM
    read amendment (§3.7) does NOT affect this count — events_in is bumped
    on the orchestrator's d-stages independent of ladder output. The
    ladder change shifts m_tvalid (measured by tb_lob_core_cycles_m06),
    not events_in.

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
        if n > 16:
            raise TimeoutError(f"events_in never bumped (still {initial})")
    assert n == 7, f"DELETE took {n} cycles, expected 7 (post-2026-05-13)"


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
async def test_steady_state_one_event_per_three_cycles(dut):
    """100 back-to-back distinct-price ADDs retire in 3*N + drain cycles.

    Post-2026-05-13 amendment (spec §3.6): hash 3-cycle latency means a new
    ADD can be accepted only every third cycle (orchestrator's hash_busy
    stall gates ADD acceptance for the duration of an in-flight hash op).
    Was 2*N + drain post-2026-05-11.

    Additionally asserts that the hash_busy stall actually fires — at least
    2*(N-1) cycles saw s_tready=0 while s_tvalid=1 (the 3-cycle hash
    occupies 2 stall cycles between accepted events). A regression on the
    stall extension would let all 100 ADDs through in <3N cycles, which
    still passes a generous bound but breaks the throughput contract."""
    _start_clock(dut)
    await _book.reset(dut)
    initial = int(dut.events_in.value)
    dut.m_tready.value = 1

    N_EVENTS = 100
    # Post-2026-05-13 amendment: 3 cycles per event (hash bound). With
    # HASH_SLOTS=512 and 100 oids, expect ~10 collisions adding 2 cycles
    # each (each extra probe is 2 cycles in the new pipeline) — round to
    # a generous 5*N + drain bound so the test stays robust if more oids
    # collide than the birthday-paradox average predicts.
    drain = 16
    max_cycles = 5 * N_EVENTS + drain

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
    # 3-cycle hash → 2 stall cycles between accepted events.
    assert observed_stall_cycles >= 2 * (N_EVENTS - 1), (
        f"expected >= {2 * (N_EVENTS - 1)} hash_busy stall cycles, got "
        f"{observed_stall_cycles}; the orchestrator's ADD stall may be missing"
    )
