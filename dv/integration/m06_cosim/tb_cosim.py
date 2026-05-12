"""M06 multi-symbol integration cosim.

Drives a multi-symbol ITCH slice through `itch_decoder -> lob_core` and
bit-compares the emitted tob_delta_t stream against `sw/refbook` filtered
to the picked-100 stock_locate set (read from
`hw/ip/lob_core/lob_core_sym_init.mem` — high bit = valid).

Adapted from `dv/integration/m05_cosim/tb_cosim.py`. The plan §H referred
to `push_moldudp_pcap` / `collect_rtl_deltas` / `iter_book_events_from_pcap`
helpers; those names do not exist in the M05 file. Per the plan's
spec-drift guard, this TB instead reuses the real M05 primitives
(`sw.replay.replay.iter_beats`, `dv/unit/itch_decoder/_axis.drive_beats`,
`sw.replay.itch_parser.parse`) and applies the M06 deltas inline:

  - refbook configured for 128 symbols, pool_capacity 16384.
  - refbook-side delta accumulator filtered on the picked-100 set.
  - Both delta lists sorted by (ingress_ts, symbol_id, side) before
    comparison so first-divergence diagnostics are readable.
  - Wallclock printed at TB end (feeds the Phase L decision on
    full-day vs sampled cosim).

Inputs (env vars):
  M06_SLICE_ITCH    Path to the multi-symbol ITCH slice.
  M06_MAX_MSGS      Optional integer cap on messages to replay (debug).
  M06_DRAIN_CYCLES  Optional integer drain cycles (default 2048).

Bit-exact comparison rule (mirrors M05):
  - Same number of deltas (after sort).
  - Same `(symbol_id, side, reason, new_best_price, new_best_size)` per
    delta.
  - DO NOT compare `ingress_ts` / `emit_ts` / `flags` directly.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

# Reuse helpers from dv/unit/lob_core/_book.py and dv/unit/itch_decoder/_axis.py.
# The Makefile sets PYTHONPATH so these import roots resolve.
from _axis import drive_beats  # type: ignore[import-not-found]
from _book import unpack_tob_delta  # type: ignore[import-not-found]

import refbook  # pybind module, sw/refbook/build on PYTHONPATH

from sw.replay import replay
from sw.replay.itch_parser import parse as parse_itch_stream
from sw.refbook.synthetic_gen import EV_ADD, EV_CANCEL, EV_DELETE, EV_EXEC, EV_EXECPX


REPO = Path(__file__).resolve().parents[3]
SYM_INIT_MEM = REPO / "hw" / "ip" / "lob_core" / "lob_core_sym_init.mem"


_TYPE_MAP = {
    EV_ADD:    refbook.EventType.Add,
    EV_CANCEL: refbook.EventType.Cancel,
    EV_DELETE: refbook.EventType.Delete,
    EV_EXEC:   refbook.EventType.Exec,
    EV_EXECPX: refbook.EventType.ExecPx,
}


def _picked_locates() -> set[int]:
    """Read picked stock_locate ids from lob_core_sym_init.mem.

    Each line is a 2-hex-char byte: bit 7 = valid; bits 6:0 = sym_idx.
    Line index == stock_locate.
    """
    out: set[int] = set()
    for i, line in enumerate(SYM_INIT_MEM.read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        v = int(line, 16)
        if v & 0x80:
            out.add(i)
    return out


def _read_itch_bytes(path: Path, max_msgs: int | None) -> bytes:
    from sw.refbook._itch_wire import MSG_LENGTHS
    out = bytearray()
    count = 0
    with replay._open_input(path) as fp:
        while True:
            if max_msgs is not None and count >= max_msgs:
                break
            hdr = fp.read(2)
            if len(hdr) < 2:
                break
            n = int.from_bytes(hdr, "big")
            body = fp.read(n)
            if len(body) < n:
                break
            count += 1
            type_byte = body[0:1]
            if type_byte not in MSG_LENGTHS:
                continue
            out += body
    return bytes(out)


def _compute_refbook_deltas(slice_path: Path, picked: set[int],
                            max_msgs: int | None
                            ) -> list[tuple[int, int, int, int, int]]:
    """Walk the slice through refbook, filtering to picked stock_locates.

    Mirrors M05's filter-at-ingress trick: lob_core's sym_idx_lut drops
    every event whose stock_locate is unmapped, so refbook must see
    exactly the same kept-set or its state diverges. Picked == the
    valid entries in lob_core_sym_init.mem.
    """
    book = refbook.Book(n_symbols=128, pool_capacity=16384,
                        initial_midprice=1_000_000)
    fast_bytes = _read_itch_bytes(slice_path, max_msgs)
    keys: list[tuple[int, int, int, int, int]] = []
    for ev_dc in parse_itch_stream(fast_bytes):
        if ev_dc is None:
            continue
        if ev_dc.symbol_id not in picked:
            continue
        ev = refbook.BookEvent()
        ev.type       = _TYPE_MAP[ev_dc.type]
        ev.side       = ev_dc.side
        ev.symbol_id  = ev_dc.symbol_id
        ev.price      = ev_dc.price
        ev.shares     = ev_dc.shares
        ev.order_id   = ev_dc.order_id
        ev.ingress_ts = ev_dc.ingress_ts
        d = book.step(ev)
        if d is None:
            continue
        keys.append((d.symbol_id, d.side, d.reason, d.new_best_price, d.new_best_size))
    return keys


@cocotb.test()
async def test_m06_cosim_bit_exact(dut):
    slice_path = Path(os.environ["M06_SLICE_ITCH"])
    max_msgs_env = os.environ.get("M06_MAX_MSGS")
    max_msgs = int(max_msgs_env) if max_msgs_env else None
    drain_cycles = int(os.environ.get("M06_DRAIN_CYCLES", "2048"))

    picked = _picked_locates()
    dut._log.info(f"m06 cosim: picked={len(picked)} stock_locates from {SYM_INIT_MEM.name}")

    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())  # 250 MHz user clock

    # Reset
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    dut.s_tkeep.value = 0
    dut.s_tuser.value = 0
    dut.m_tready.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    captured: list[tuple[int, int, int, int, int, int, int]] = []

    async def _capture():
        dut.m_tready.value = 1
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_tvalid.value) and int(dut.m_tready.value):
                d = unpack_tob_delta(int(dut.m_tdata.value))
                captured.append((d.ingress_ts, d.symbol_id, d.side, d.reason,
                                 d.new_best_price, d.new_best_size, d.flags))

    cap_task = cocotb.start_soon(_capture())

    t0 = time.monotonic()

    beats = list(replay.iter_beats(slice_path, max_messages=max_msgs))
    dut._log.info(f"m06 cosim: driving {len(beats)} AXI-S beats from {slice_path}")
    await drive_beats(dut, beats, progress_every=200_000)

    for _ in range(drain_cycles):
        await RisingEdge(dut.clk)
    cap_task.cancel()

    elapsed = time.monotonic() - t0
    print(f"M06 cosim wallclock: {elapsed:.1f}s")

    dut._log.info(f"m06 cosim: captured {len(captured)} TOB deltas from RTL")
    dut._log.info(
        f"m06 cosim stats: events_in={int(dut.events_in.value)} "
        f"events_filtered={int(dut.events_filtered.value)} "
        f"tob_deltas_out={int(dut.tob_deltas_out.value)} "
        f"sym_lut_misses={int(dut.sym_lut_misses.value)} "
        f"rebases_total={int(dut.rebases_total.value)} "
        f"stale_drops={int(dut.stale_drops.value)} "
        f"pool_leaks_freed={int(dut.pool_leaks_freed.value)} "
        f"epoch_wraps={int(dut.epoch_wraps.value)}"
    )

    expected_keys = _compute_refbook_deltas(slice_path, picked, max_msgs)
    dut._log.info(f"m06 cosim: refbook produced {len(expected_keys)} filtered deltas")

    # Sort both sides by (ingress_ts, symbol_id, side) before comparing.
    # The multi-symbol stream interleaves deltas across syms; without a
    # canonical order the diff is unreadable. The compare key is still
    # (symbol_id, side, reason, new_best_price, new_best_size) — we strip
    # ingress_ts from the tuple after sorting.
    rtl_sorted = sorted(captured, key=lambda t: (t[0], t[1], t[2]))
    rtl_keys = [(s, sd, rs, p, sz) for (_ts, s, sd, rs, p, sz, _f) in rtl_sorted]

    ref_sorted = sorted(expected_keys, key=lambda k: (k[0], k[1]))
    # ref tuples are already (sym, side, reason, price, size); no ts to strip.

    # Debug dumps
    with open("/tmp/m06_rtl_deltas.txt", "w") as f:
        for i, k in enumerate(rtl_keys):
            f.write(f"{i}\t{k}\n")
    with open("/tmp/m06_ref_deltas.txt", "w") as f:
        for i, k in enumerate(ref_sorted):
            f.write(f"{i}\t{k}\n")

    # Sanity invariants from §3.7 — surface even if the bit-exact compare
    # ends up tripped on the very first delta.
    assert int(dut.sym_lut_misses.value) > 0, "expected unpicked-symbol drops"
    assert int(dut.pool_leaks_freed.value) == int(dut.stale_drops.value), (
        f"pool_leaks_freed ({int(dut.pool_leaks_freed.value)}) != "
        f"stale_drops ({int(dut.stale_drops.value)})"
    )

    if len(rtl_keys) != len(ref_sorted):
        n = min(len(rtl_keys), len(ref_sorted))
        first_diff = next(
            (i for i in range(n) if rtl_keys[i] != ref_sorted[i]),
            n,
        )
        msg = (
            f"length mismatch: RTL={len(rtl_keys)} refbook={len(ref_sorted)} "
            f"first-diverging-index={first_diff}"
        )
        ctx_lo = max(0, first_diff - 3)
        ctx_hi = min(max(len(rtl_keys), len(ref_sorted)), first_diff + 8)
        msg += "\n  --- surrounding deltas ---"
        for i in range(ctx_lo, ctx_hi):
            mark = " <<<" if i == first_diff else ""
            r = rtl_keys[i] if i < len(rtl_keys) else "(end)"
            e = ref_sorted[i] if i < len(ref_sorted) else "(end)"
            msg += f"\n  [{i}] RTL={r} REF={e}{mark}"
        raise AssertionError(msg)

    for i, (a, e) in enumerate(zip(rtl_keys, ref_sorted, strict=True)):
        if a != e:
            raise AssertionError(
                f"delta mismatch at index {i}:\n  RTL={a}\n  REF={e}"
            )

    dut._log.info(f"byte-exact: {len(rtl_keys)} deltas across {len(picked)} symbols")


_ = sys.modules[__name__]
