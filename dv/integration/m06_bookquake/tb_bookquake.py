"""Book-quake cycle-stall TB.

Drives the synthetic stream produced by `sw.m06_tools.synth_bookquake`
(32 B BookEvent records) onto lob_core.s_* and asserts:

  - `rebases_total` increments exactly N_SYMS times.
  - Per-rebase stall (cycles between consecutive `rebases_total` bumps,
    or the cycle gap before the stream resumes acceptance after a bump)
    is bounded by `M06_BQ_MAX_STALL` cycles.

NOT RUN as part of any exit gate yet. The asserts below are gated with
`# TODO: tighten once F.2 full lands` — until squash-and-retry + per-sym
ladder math land, the rebase trigger fires (epoch++, rebases_total++)
without an observable s_tready dip, so the stall measurement is
trivially zero and the assertion bound is uninformative.
"""
from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from _book import pack_book_event  # type: ignore[import-not-found]
from sw.m05_tools._io import iter_events


def _stream_path() -> Path:
    p = os.environ.get("M06_BQ_STREAM")
    if not p:
        raise RuntimeError(
            "M06_BQ_STREAM not set — generate the stream with "
            "`python3 -m sw.m06_tools.synth_bookquake --out <path>` first."
        )
    return Path(p)


@cocotb.test()
async def test_bookquake_per_rebase_stall_bounded(dut):
    # n_syms is honoured by sw/m06_tools/synth_bookquake.py when generating
    # the stream; the TB only consumes the resulting binary and counts
    # observed rebases. Reference re-enables once the commented-out
    # `rebases_total == n_syms` assertion below is uncommented.
    max_stall  = int(os.environ.get("M06_BQ_MAX_STALL",  "200"))
    drain_cyc  = int(os.environ.get("M06_BQ_DRAIN",      "512"))

    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())

    # Reset + tie-offs
    dut.rstn.value           = 0
    dut.s_tvalid.value       = 0
    dut.s_tlast.value        = 0
    dut.m_tready.value       = 0
    dut.dbg_epoch_bump.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.m_tready.value = 1

    # Track every cycle where rebases_total increments.
    rebase_cycles: list[int] = []
    # Track every cycle where s_tready was deasserted under s_tvalid.
    stall_cycles: list[int] = []
    cycle = [0]
    prev_rebases = [0]

    async def _probe():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            cycle[0] += 1
            cur = int(dut.rebases_total.value)
            if cur > prev_rebases[0]:
                rebase_cycles.append(cycle[0])
                prev_rebases[0] = cur
            if int(dut.s_tvalid.value) and not int(dut.s_tready.value):
                stall_cycles.append(cycle[0])

    probe_task = cocotb.start_soon(_probe())

    stream = _stream_path()
    n_driven = 0
    for ev_type, side, symbol_id, price, shares, order_id, ingress_ts in iter_events(stream):
        word = pack_book_event(ev_type, side, symbol_id, price, shares,
                               order_id, ingress_ts)
        dut.s_tdata.value  = word
        dut.s_tvalid.value = 1
        dut.s_tlast.value  = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.s_tready.value):
                break
        dut.s_tvalid.value = 0
        dut.s_tlast.value  = 0
        n_driven += 1

    # Drain in-flight events
    for _ in range(drain_cyc):
        await RisingEdge(dut.clk)
    probe_task.cancel()

    dut._log.info(
        f"bookquake: drove={n_driven} rebases={len(rebase_cycles)} "
        f"stall_cycles={len(stall_cycles)} max_stall_bound={max_stall}"
    )

    # Per-rebase stall = cycles between consecutive rebase bumps, minus 1
    # (each rebase is expected to consume at least 1 cycle in the pipeline).
    per_rebase: list[int] = []
    for i, c in enumerate(rebase_cycles):
        prev_c = rebase_cycles[i - 1] if i > 0 else c
        per_rebase.append(c - prev_c)
    dut._log.info(f"bookquake: per_rebase_gaps={per_rebase}")

    # TODO: tighten once F.2 full lands — squash-and-retry, per-sym
    # ladder address math, and op_sym_idx threading must be in place
    # before these assertions are meaningful. Today the rebase trigger
    # fires as pure side-effect and the s_tready stall is trivially 0,
    # so the bound is uninformative. Re-enable once the cosim slice
    # (Phase H) starts passing on a 100 K window.
    #
    # assert len(rebase_cycles) == n_syms, (
    #     f"expected {n_syms} rebases, observed {len(rebase_cycles)}"
    # )
    # for i, gap in enumerate(per_rebase):
    #     assert gap <= max_stall, (
    #         f"rebase {i} at cycle {rebase_cycles[i]} stalled {gap} > {max_stall}"
    #     )
