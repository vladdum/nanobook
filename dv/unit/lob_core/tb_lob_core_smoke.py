"""Minimal smoke TB: drive a few book_event_t beats, confirm the orchestrator
accepts them and bumps `events_in` once the pipeline drains.

Phase C (stub) asserted m_tvalid==0; Phase H wires the real datapath through
to tob_tracker, so 5 distinct-price ADDs do produce TOB deltas. The smoke
TB now drains the pipeline before reading events_in (which bumps at retire,
NOT at handshake — see lob_core.sv Phase H header)."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _book


@cocotb.test()
async def test_stub_accepts_events(dut):
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _book.reset(dut)
    dut.m_tready.value = 1
    for i in range(5):
        ev = _book.pack_book_event(
            ev_type=0,    # EV_ADD
            side=0,
            symbol_id=42,
            price=10000 + i,
            shares=100,
            order_id=1000 + i,
            ingress_ts=i,
        )
        await _book.push_event(dut, ev)
    # Drain the 4-stage ADD pipeline (events_in bumps at retire).
    for _ in range(12):
        await RisingEdge(dut.clk)
    assert int(dut.events_in.value) == 5, f"got events_in={int(dut.events_in.value)}"
