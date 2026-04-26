"""TB for hw/ip/itch_decoder/extract_delete.sv."""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import _axis
from synthetic_gen import _encode_itch, BookEvent, EV_DELETE


async def _drive_and_capture(dut, msg: bytes, *, tuser: int = 0) -> int:
    dut.m_ready.value = 1
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=tuser))
    for _ in range(1024):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            ev = int(dut.m_event.value)
            await drive
            return ev
    raise TimeoutError("m_valid never asserted")


def _unpack(event_int: int) -> dict:
    return {
        "ev_type":    (event_int >> 248) & 0xFF,
        "side":       (event_int >> 240) & 0xFF,
        "symbol_id":  (event_int >> 224) & 0xFFFF,
        "price":      (event_int >> 192) & 0xFFFFFFFF,
        "shares":     (event_int >> 160) & 0xFFFFFFFF,
        "order_id":   (event_int >>  64) & 0xFFFFFFFFFFFFFFFF,
        "ingress_ts": (event_int >>   0) & 0xFFFFFFFFFFFFFFFF,
    }


async def _reset(dut):
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0
    dut.s_tuser.value  = 0
    dut.m_ready.value  = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_delete_basic(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_DELETE, 0, 42, 0, 0, 0xDEADBEEF12345678, 0xCAFE)
    msg = _encode_itch(ev)
    assert msg[:1] == b"D" and len(msg) == 19
    event_int = await _drive_and_capture(dut, msg, tuser=0xCAFE)
    f = _unpack(event_int)
    assert f["ev_type"]    == 0x02
    assert f["symbol_id"]  == 42
    assert f["order_id"]   == 0xDEADBEEF12345678
    assert f["price"]      == 0
    assert f["shares"]     == 0
    assert f["ingress_ts"] == 0xCAFE


@cocotb.test()
async def test_delete_max_order_id(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_DELETE, 0, 1, 0, 0, 0xFFFFFFFFFFFFFFFF, 0x01)
    msg = _encode_itch(ev)
    event_int = await _drive_and_capture(dut, msg, tuser=1)
    f = _unpack(event_int)
    assert f["order_id"] == 0xFFFFFFFFFFFFFFFF
    assert f["symbol_id"] == 1


@cocotb.test()
async def test_delete_max_symbol(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_DELETE, 0, 0xFFFF, 0, 0, 0xCAFE, 0x100)
    msg = _encode_itch(ev)
    event_int = await _drive_and_capture(dut, msg, tuser=0x100)
    f = _unpack(event_int)
    assert f["symbol_id"] == 0xFFFF
