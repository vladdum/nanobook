"""M04 cosim: drive a NASDAQ historical (or slice) file through itch_decoder RTL.

Inputs (env vars):
  COSIM_ITCH       Path to NASDAQ historical (.gz / .zst / raw) file.
  COSIM_OUT        Path to write actual_events.bin.
  COSIM_OUT_SLOW   Path to write actual_slow_count.txt.
  COSIM_MAX_MSGS   Optional integer cap on messages to replay.

Reads slow_path_dropped at end via DUT signal access.
"""
from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from dv.unit.itch_decoder._axis import capture_book_events, drive_beats
from sw.refbook.synthetic_gen import BookEvent
from sw.replay import event_bin, replay


@cocotb.test()
async def test_cosim(dut):
    """Drive ITCH bytes through the decoder, capture book_event_t output."""
    src = Path(os.environ["COSIM_ITCH"])
    out = Path(os.environ["COSIM_OUT"])
    out_slow = Path(os.environ["COSIM_OUT_SLOW"])
    max_msgs_env = os.environ.get("COSIM_MAX_MSGS")
    max_msgs = int(max_msgs_env) if max_msgs_env else None

    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())  # 250 MHz

    # Reset
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.m_tready.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    # Spawn capture coroutine — collects BookEvent records as they arrive.
    captured: list[BookEvent] = []
    cap_task = cocotb.start_soon(capture_book_events(dut, captured))

    # Drive replay beats. Log progress every 500K beats — the 10M-msg sweep
    # is tens of minutes wall and the per-day cosim log is otherwise silent
    # between the "Running tests" banner and the final summary. With ~25
    # beats per ITCH msg the 10M-msg input is ~250M beats, so 500K = ~500
    # progress lines / day — chatty but cheap, and lets the orchestrator
    # confirm liveness from outside.
    beats = list(replay.iter_beats(src, max_messages=max_msgs))
    dut._log.info(f"cosim: driving {len(beats)} AXI-S beats from {src}")
    await drive_beats(dut, beats, progress_every=500_000)

    # Drain — wait for the pipeline to flush.
    for _ in range(64):
        await RisingEdge(dut.clk)
    cap_task.cancel()

    # Dump captured events.
    with out.open("wb") as fp:
        for ev in captured:
            event_bin.write(fp, ev)

    # Read slow_path_dropped via DUT signal access.
    await ReadOnly()
    slow = int(dut.slow_path_dropped.value)
    out_slow.write_text(str(slow))

    dut._log.info(
        f"cosim done: {len(captured)} events captured; "
        f"slow_path_dropped={slow}"
    )
