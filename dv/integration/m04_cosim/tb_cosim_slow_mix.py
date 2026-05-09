"""Cosim with a hand-built mixed fast/slow stream.

10 fast-path events interleaved with 10 slow-path messages → assert:
- captured count == 10
- slow_path_dropped == 10
"""
from __future__ import annotations

from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge

from dv.unit.itch_decoder._axis import capture_book_events, drive_beats
from sw.refbook import synthetic_gen
from sw.refbook.synthetic_gen import EV_ADD, BookEvent
from sw.replay import replay


def _build_mixed_pcap(tmp_dir: Path) -> Path:
    """10 ADDs interleaved with 10 slow-path 'S' messages."""
    src = tmp_dir / "mix.itch"
    raw = bytearray()
    for i in range(10):
        ev = BookEvent(
            type=EV_ADD, side=0, symbol_id=i, price=100,
            shares=10, order_id=i, ingress_ts=0,
        )
        msg = synthetic_gen._encode_itch(ev)
        raw += len(msg).to_bytes(2, "big") + msg
        slow_msg = synthetic_gen._encode_itch_slow_path(b"S")
        raw += len(slow_msg).to_bytes(2, "big") + slow_msg
    src.write_bytes(bytes(raw))
    return src


@cocotb.test()
async def test_mixed_stream(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.m_tready.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    work = Path("/tmp/m04_cosim_slow")
    work.mkdir(parents=True, exist_ok=True)
    src = _build_mixed_pcap(work)

    captured: list[BookEvent] = []
    cap_task = cocotb.start_soon(capture_book_events(dut, captured))
    await drive_beats(dut, list(replay.iter_beats(src)))
    for _ in range(64):
        await RisingEdge(dut.clk)
    cap_task.cancel()

    await ReadOnly()
    slow = int(dut.slow_path_dropped.value)

    assert len(captured) == 10, f"expected 10 events, got {len(captured)}"
    assert slow == 10, f"expected slow_path_dropped=10, got {slow}"
