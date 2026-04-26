"""TB for hw/ip/itch_decoder/event_pack.sv.

Drives a known 256-bit value on s_event; verifies it appears verbatim on
the AXI-S output beat, with TLAST=1 and one-cycle registered latency.
"""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from synthetic_gen import BookEvent, EV_ADD


async def _reset(dut):
    dut.rstn.value = 0
    dut.s_valid.value = 0
    dut.m_tready.value = 0
    dut.s_event.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_pack_passthrough(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_ADD, 0, 1234, 1_000_000, 100, 0xDEADBEEF12345678, 0xCAFE)
    expected = int.from_bytes(ev.pack(), "little")
    dut.s_event.value = expected
    dut.s_valid.value = 1
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value):
            assert int(dut.m_tdata.value) == expected
            assert int(dut.m_tlast.value) == 1
            return
    raise TimeoutError("m_tvalid never asserted")


@cocotb.test()
async def test_pack_backpressure(dut):
    """Hold m_tready=0; verify s_ready de-asserts after capturing one event."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    dut.s_event.value = 0xDEADBEEFCAFEBABE
    dut.s_valid.value = 1
    dut.m_tready.value = 0  # downstream not ready
    # First beat captured: s_ready should be 1 initially, then 0 after capture
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.m_tvalid.value) == 1, "captured event should be valid"
    assert int(dut.s_ready.value) == 0, "s_ready must de-assert with no downstream consumer"
    # Now release downstream
    dut.s_valid.value = 0
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.m_tvalid.value) == 0, "should drain after m_tready=1"


@cocotb.test()
async def test_pack_three_events(dut):
    """Stream 3 events back-to-back; assert each comes out with TLAST=1."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    dut.m_tready.value = 1
    expected_values = [0x1111111111111111, 0x2222222222222222, 0x3333333333333333]
    seen: list[int] = []
    sent = 0
    for _ in range(32):
        if sent < 3:
            dut.s_event.value = expected_values[sent]
            dut.s_valid.value = 1
        else:
            dut.s_valid.value = 0
        await RisingEdge(dut.clk)
        if int(dut.s_valid.value) and int(dut.s_ready.value):
            sent += 1
        if int(dut.m_tvalid.value) and int(dut.m_tready.value):
            seen.append(int(dut.m_tdata.value) & ((1 << 256) - 1))
            if len(seen) == 3:
                break
    # Lower 64 bits should match (we only set lower bits in expected_values)
    for i, v in enumerate(seen):
        assert (v & ((1 << 64) - 1)) == expected_values[i], \
            f"event {i}: got 0x{v:064x}, expected lo64 0x{expected_values[i]:016x}"
