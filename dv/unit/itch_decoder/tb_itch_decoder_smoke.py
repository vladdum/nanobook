"""Smoke test — instantiates the stub itch_decoder, walks one clock,
asserts the output is held inactive (it's a stub)."""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


@cocotb.test()
async def test_smoke(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())  # 250 MHz
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0
    dut.s_tdata.value  = 0
    dut.s_tkeep.value  = 0
    dut.s_tuser.value  = 0
    dut.m_tready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk)

    # Stub guarantees: no output, no counters increment.
    assert int(dut.m_tvalid.value)      == 0, "stub should not emit"
    assert int(dut.events_emitted.value) == 0, "stub should not count events"
    assert int(dut.s_tready.value)      == 1, "stub should accept input"
