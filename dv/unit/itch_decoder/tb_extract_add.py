"""TB for hw/ip/itch_decoder/extract_add.sv."""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import _axis
from synthetic_gen import _encode_itch, BookEvent, EV_ADD


async def _drive_and_capture(dut, msg: bytes, *, tuser: int = 0) -> int:
    """Drive `msg` on input AXI-S; wait for m_valid; return packed m_event."""
    dut.m_ready.value = 1
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=tuser))
    for _ in range(1024):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            event_int = int(dut.m_event.value)
            await drive
            return event_int
    raise TimeoutError("m_valid never asserted")


def _unpack(event_int: int) -> dict:
    """Slice book_event_t fields out of the 256-bit packed value."""
    return {
        "ev_type":     (event_int >> 248) & 0xFF,
        "side":        (event_int >> 240) & 0xFF,
        "symbol_id":   (event_int >> 224) & 0xFFFF,
        "price":       (event_int >> 192) & 0xFFFFFFFF,
        "shares":      (event_int >> 160) & 0xFFFFFFFF,
        "order_id":    (event_int >>  64) & 0xFFFFFFFFFFFFFFFF,
        "ingress_ts":  (event_int >>   0) & 0xFFFFFFFFFFFFFFFF,
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
async def test_add_basic_buy(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    # Construct a known BookEvent and encode to ITCH 'A'.
    ev = BookEvent(EV_ADD, 0, 1234, 1_000_000, 100, 0xDEADBEEF12345678, 0xCAFE)
    msg = _encode_itch(ev)
    assert msg[:1] == b"A" and len(msg) == 36
    event_int = await _drive_and_capture(dut, msg, tuser=0xCAFE)
    fields = _unpack(event_int)
    assert fields["ev_type"]    == 0x00,             f"got ev_type={fields['ev_type']}"
    assert fields["side"]       == 0,                f"got side={fields['side']}"
    assert fields["symbol_id"]  == 1234,             f"got symbol_id={fields['symbol_id']}"
    assert fields["price"]      == 1_000_000,        f"got price={fields['price']}"
    assert fields["shares"]     == 100,              f"got shares={fields['shares']}"
    assert fields["order_id"]   == 0xDEADBEEF12345678
    assert fields["ingress_ts"] == 0xCAFE


@cocotb.test()
async def test_add_basic_sell(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_ADD, 1, 7, 500_000, 50, 99, 2)
    msg = _encode_itch(ev)
    event_int = await _drive_and_capture(dut, msg, tuser=2)
    fields = _unpack(event_int)
    assert fields["ev_type"]   == 0x00
    assert fields["side"]      == 1
    assert fields["symbol_id"] == 7
    assert fields["order_id"]  == 99
    assert fields["price"]     == 500_000
    assert fields["shares"]    == 50


@cocotb.test()
async def test_add_max_values(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    # Max 16-bit symbol_id, max 32-bit price/shares, large order_id.
    ev = BookEvent(EV_ADD, 0, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
                   0xDEADBEEFCAFEBABE, 0xABCDEF)
    msg = _encode_itch(ev)
    event_int = await _drive_and_capture(dut, msg, tuser=0xABCDEF)
    fields = _unpack(event_int)
    assert fields["symbol_id"] == 0xFFFF
    assert fields["price"]     == 0xFFFFFFFF
    assert fields["shares"]    == 0xFFFFFFFF
    assert fields["order_id"]  == 0xDEADBEEFCAFEBABE
