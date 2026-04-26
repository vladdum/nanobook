"""TB for hw/ip/itch_decoder/field_extract.sv.

Drives ITCH messages on each of the 5 dispatch lanes; verifies the
correct book_event_t emerges on the single output.
"""
from __future__ import annotations
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from synthetic_gen import (
    _encode_itch, BookEvent,
    EV_ADD, EV_DELETE, EV_CANCEL, EV_EXEC,
)


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


async def _drive_lane(dut, lane: str, msg: bytes, *, tuser: int = 0):
    """Drive `msg` on dispatch_<lane>_*; uses 8-byte little-endian beats per AXI-S spec."""
    n = len(msg)
    full_beats = n // 8
    tail = n % 8
    total_beats = full_beats + (1 if tail else 0)

    tdata = getattr(dut, f"dispatch_{lane}_tdata")
    tkeep = getattr(dut, f"dispatch_{lane}_tkeep")
    tvalid = getattr(dut, f"dispatch_{lane}_tvalid")
    tlast = getattr(dut, f"dispatch_{lane}_tlast")
    tuser_sig = getattr(dut, f"dispatch_{lane}_tuser")
    tready = getattr(dut, f"dispatch_{lane}_tready")

    for i in range(total_beats):
        chunk = msg[i*8 : i*8 + 8]
        if len(chunk) < 8:
            chunk = chunk + b"\x00" * (8 - len(chunk))
            keep = (1 << tail) - 1
        else:
            keep = 0xFF
        tdata.value = int.from_bytes(chunk, "little")
        tkeep.value = keep
        tvalid.value = 1
        tlast.value  = 1 if i == total_beats - 1 else 0
        tuser_sig.value = tuser if i == 0 else 0
        await RisingEdge(dut.clk)
        while int(tready.value) == 0:
            await RisingEdge(dut.clk)
    tvalid.value = 0
    tlast.value = 0


async def _capture_event(dut, *, max_cycles: int = 1024) -> int:
    """Wait for m_valid; return packed m_event."""
    dut.m_ready.value = 1
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            return int(dut.m_event.value)
    raise TimeoutError("m_valid never asserted")


async def _capture_n_events(dut, n: int, *, max_cycles: int = 2048) -> list[int]:
    """Capture exactly `n` events emitted from the output."""
    dut.m_ready.value = 1
    events: list[int] = []
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_valid.value):
            events.append(int(dut.m_event.value))
            if len(events) == n:
                return events
    raise TimeoutError(f"only saw {len(events)} events; expected {n}")


async def _reset(dut):
    dut.rstn.value = 0
    for lane in ("add", "exec", "cancel", "delete", "replace"):
        getattr(dut, f"dispatch_{lane}_tvalid").value = 0
        getattr(dut, f"dispatch_{lane}_tlast").value  = 0
        getattr(dut, f"dispatch_{lane}_tuser").value  = 0
    dut.m_ready.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_route_add(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_ADD, 0, 1234, 1_000_000, 100, 0xDEADBEEF, 0xCAFE)
    msg = _encode_itch(ev)
    cocotb.start_soon(_drive_lane(dut, "add", msg, tuser=0xCAFE))
    event_int = await _capture_event(dut)
    f = _unpack(event_int)
    assert f["ev_type"]   == 0x00
    assert f["symbol_id"] == 1234
    assert f["order_id"]  == 0xDEADBEEF


@cocotb.test()
async def test_route_exec(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_EXEC, 0, 7, 0, 50, 0xABCD, 1)
    msg = _encode_itch(ev)
    cocotb.start_soon(_drive_lane(dut, "exec", msg, tuser=1))
    event_int = await _capture_event(dut)
    f = _unpack(event_int)
    assert f["ev_type"]   == 0x03
    assert f["symbol_id"] == 7
    assert f["order_id"]  == 0xABCD


@cocotb.test()
async def test_route_cancel(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_CANCEL, 0, 99, 0, 30, 0xCAFE, 1)
    msg = _encode_itch(ev)
    cocotb.start_soon(_drive_lane(dut, "cancel", msg, tuser=1))
    event_int = await _capture_event(dut)
    f = _unpack(event_int)
    assert f["ev_type"]   == 0x01
    assert f["symbol_id"] == 99
    assert f["shares"]    == 30


@cocotb.test()
async def test_route_delete(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    ev = BookEvent(EV_DELETE, 0, 42, 0, 0, 0xDEAD, 1)
    msg = _encode_itch(ev)
    cocotb.start_soon(_drive_lane(dut, "delete", msg, tuser=1))
    event_int = await _capture_event(dut)
    f = _unpack(event_int)
    assert f["ev_type"]   == 0x02
    assert f["order_id"]  == 0xDEAD


@cocotb.test()
async def test_route_replace_emits_two(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    # ITCH 'U' message: 35 bytes
    msg = (
        b"U"
        + (42).to_bytes(2, "big")          # stock_locate
        + b"\x00\x00"                      # tracking
        + (0xCAFE).to_bytes(6, "big")      # timestamp
        + (0xDEADBEEF12345678).to_bytes(8, "big")   # orig_oid
        + (0xAAAAAAAABBBBBBBB).to_bytes(8, "big")   # new_oid
        + (100).to_bytes(4, "big")         # shares
        + (1_000_000).to_bytes(4, "big")   # price
    )
    assert len(msg) == 35
    cocotb.start_soon(_drive_lane(dut, "replace", msg, tuser=0xCAFE))
    events = await _capture_n_events(dut, 2)
    delete_f = _unpack(events[0])
    add_f    = _unpack(events[1])
    assert delete_f["ev_type"] == 0x02
    assert delete_f["order_id"] == 0xDEADBEEF12345678
    assert add_f["ev_type"]    == 0x00
    assert add_f["order_id"]   == 0xAAAAAAAABBBBBBBB
    assert add_f["price"]      == 1_000_000
    assert int(dut.replace_split.value) == 1
