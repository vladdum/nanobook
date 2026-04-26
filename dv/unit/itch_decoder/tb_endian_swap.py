"""TB for hw/ip/itch_decoder/endian_swap.sv.

Verifies that endian_swap reverses all 32 bytes so the output matches
BookEvent.pack()'s memory layout when interpreted as little-endian-byte-lane.
"""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from synthetic_gen import BookEvent, EV_ADD, EV_DELETE, EV_CANCEL, EV_EXEC


def _packed_struct_to_int(ev: BookEvent) -> int:
    """SV book_event_t natural layout (type at MSB end, ingress_ts at LSB end)
    that matches what the extractors produce. Each field stored as its natural
    integer value at its assigned bit range."""
    return (
        (ev.type       << 248)
        | (ev.side     << 240)
        | (ev.symbol_id << 224)
        | (ev.price    << 192)
        | (ev.shares   << 160)
        # _pad = 0 at [159:128]
        | (ev.order_id << 64)
        | (ev.ingress_ts)
    )


def _expected_axis_int(ev: BookEvent) -> int:
    """The expected output: BookEvent.pack() bytes treated as little-endian byte-lane
    (byte 0 of pack() at TDATA[7:0])."""
    return int.from_bytes(ev.pack(), "little")


async def _drive_one(dut, ev: BookEvent) -> int:
    s_int = _packed_struct_to_int(ev)
    dut.s_event.value = s_int
    dut.s_valid.value = 1
    dut.m_ready.value = 1
    await RisingEdge(dut.clk)
    while int(dut.s_ready.value) == 0:
        await RisingEdge(dut.clk)
    dut.s_valid.value = 0
    # Wait for output
    for _ in range(16):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            out = int(dut.m_event.value)
            return out
    raise TimeoutError("m_valid never asserted")


async def _reset(dut):
    dut.rstn.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 0
    dut.s_event.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_swap_add(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_ADD, 0, 1234, 1_000_000, 100, 0xDEADBEEF12345678, 0xCAFE)
    out = await _drive_one(dut, ev)
    assert out == _expected_axis_int(ev), \
        f"got 0x{out:064x}, expected 0x{_expected_axis_int(ev):064x}"


@cocotb.test()
async def test_swap_delete(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_DELETE, 0, 7, 0, 0, 0xABCD, 0x42)
    out = await _drive_one(dut, ev)
    assert out == _expected_axis_int(ev), \
        f"got 0x{out:064x}, expected 0x{_expected_axis_int(ev):064x}"


@cocotb.test()
async def test_swap_cancel(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_CANCEL, 0, 0xFFFF, 0, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xCAFE)
    out = await _drive_one(dut, ev)
    assert out == _expected_axis_int(ev)


@cocotb.test()
async def test_swap_exec(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_EXEC, 1, 42, 0, 75, 0xDEADBEEF, 0x100)
    out = await _drive_one(dut, ev)
    assert out == _expected_axis_int(ev)
