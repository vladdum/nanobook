"""TB for hw/ip/itch_decoder/extract_replace.sv (ITCH U → DELETE + ADD)."""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import _axis
# Note: this TB constructs ITCH 'U' messages manually (synthetic_gen
# doesn't emit U today) so it doesn't need _encode_itch / BookEvent.


def _make_replace_msg(symbol_id: int, ts48: int, orig_oid: int,
                      new_oid: int, shares: int, price: int) -> bytes:
    """Construct an ITCH 'U' message manually (synthetic_gen doesn't produce U today)."""
    # 1B type + 2B stock_locate + 2B tracking + 6B timestamp + 8B orig_oid + 8B new_oid + 4B shares + 4B price
    return (
        b"U"
        + (symbol_id & 0xFFFF).to_bytes(2, "big")
        + b"\x00\x00"  # tracking, ignored
        + ts48.to_bytes(6, "big")
        + orig_oid.to_bytes(8, "big")
        + new_oid.to_bytes(8, "big")
        + shares.to_bytes(4, "big")
        + price.to_bytes(4, "big")
    )


async def _drive_and_capture_two(dut, msg: bytes, *, tuser: int = 0) -> tuple[int, int]:
    """Drive U message; collect both DELETE and ADD events."""
    dut.m_ready.value = 1
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=tuser))
    events: list[int] = []
    for _ in range(2048):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            events.append(int(dut.m_event.value))
            if len(events) == 2:
                await drive
                return events[0], events[1]
    raise TimeoutError(f"only saw {len(events)} events; expected 2")


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
async def test_replace_basic(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = _make_replace_msg(symbol_id=42, ts48=0xCAFE,
                             orig_oid=0xDEADBEEF12345678,
                             new_oid=0xAAAAAAAABBBBBBBB,
                             shares=100, price=1_000_000)
    ev_del_int, ev_add_int = await _drive_and_capture_two(dut, msg, tuser=0xCAFE)

    delete = _unpack(ev_del_int)
    assert delete["ev_type"]    == 0x02, "DELETE comes first"
    assert delete["symbol_id"]  == 42
    assert delete["order_id"]   == 0xDEADBEEF12345678
    assert delete["price"]      == 0
    assert delete["shares"]     == 0
    assert delete["ingress_ts"] == 0xCAFE

    add = _unpack(ev_add_int)
    assert add["ev_type"]    == 0x00, "ADD comes second"
    assert add["symbol_id"]  == 42
    assert add["order_id"]   == 0xAAAAAAAABBBBBBBB
    assert add["price"]      == 1_000_000
    assert add["shares"]     == 100
    assert add["ingress_ts"] == 0xCAFE

    assert int(dut.replace_split.value) == 1, "replace_split bumps once per U input"


@cocotb.test()
async def test_replace_two_messages(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg1 = _make_replace_msg(1, 0x100, 0xAAAA, 0xBBBB, 50, 500_000)
    msg2 = _make_replace_msg(2, 0x200, 0xCCCC, 0xDDDD, 75, 750_000)
    d1, a1 = await _drive_and_capture_two(dut, msg1, tuser=0x100)
    d2, a2 = await _drive_and_capture_two(dut, msg2, tuser=0x200)
    assert _unpack(d1)["order_id"] == 0xAAAA
    assert _unpack(a1)["order_id"] == 0xBBBB
    assert _unpack(d2)["order_id"] == 0xCCCC
    assert _unpack(a2)["order_id"] == 0xDDDD
    assert int(dut.replace_split.value) == 2


@cocotb.test()
async def test_replace_max_values(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = _make_replace_msg(0xFFFF, 0xFFFFFF,
                             0xFFFFFFFFFFFFFFFF, 0xCAFEBABEDEADBEEF,
                             0xFFFFFFFF, 0xFFFFFFFF)
    ev_del_int, ev_add_int = await _drive_and_capture_two(dut, msg, tuser=0xFFFFFF)
    delete = _unpack(ev_del_int)
    add    = _unpack(ev_add_int)
    assert delete["order_id"] == 0xFFFFFFFFFFFFFFFF
    assert add["order_id"]    == 0xCAFEBABEDEADBEEF
    assert add["price"]       == 0xFFFFFFFF
    assert add["shares"]      == 0xFFFFFFFF
