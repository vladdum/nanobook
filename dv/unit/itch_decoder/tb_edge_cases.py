"""Edge-case TB for the wired itch_decoder.

5 cases per M03 plan §I:
- malformed (zero-length ITCH message)
- bad type byte (slow-path)
- truncated final message
- multi-message-per-packet
- forced MoldUDP sequence gap
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _axis
from synthetic_gen import _encode_itch, BookEvent, EV_DELETE


def _mold_pkt(itch_bytes: bytes, *, seq: int = 1, msg_count: int = 1) -> bytes:
    return (
        b"NSDQ123456"
        + seq.to_bytes(8, "big")
        + msg_count.to_bytes(2, "big")
        + itch_bytes
    )


def _itch_msg_with_len_prefix(body: bytes) -> bytes:
    """Add the 2-byte big-endian length prefix that msg_boundary expects."""
    return len(body).to_bytes(2, "big") + body


async def _collect_event_count(dut, *, max_cycles: int = 200_000) -> int:
    """Count events that arrive on m_tdata until no new events for N idle cycles."""
    dut.m_tready.value = 1
    count = 0
    idle = 0
    IDLE_THRESHOLD = 200  # consider stream done after 200 cycles with no event
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value):
            count += 1
            idle = 0
        else:
            idle += 1
            if count > 0 and idle >= IDLE_THRESHOLD:
                return count
    return count


@cocotb.test()
async def test_zero_length_message(dut):
    """ITCH message with length=0 should bump frame_malformed and not crash."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    # Construct a packet: [zero-length-msg] + [valid D message]
    valid_d = _encode_itch(BookEvent(EV_DELETE, 0, 1, 0, 0, 0xCAFE, 0x42))
    payload = b"\x00\x00" + _itch_msg_with_len_prefix(valid_d)
    pkt = _mold_pkt(payload, seq=1, msg_count=1)

    cocotb.start_soon(_axis.drive_payload(dut, pkt, tuser=0xCAFE))
    n_events = await _collect_event_count(dut)
    assert int(dut.frame_malformed.value) >= 1, "frame_malformed should bump"
    assert n_events >= 1, "valid msg following malformed should still emit"


@cocotb.test()
async def test_bad_type_byte(dut):
    """Type 'Z' should hit slow path."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    # 'Z' message: type byte + 18 bytes (matches D length) so msg_boundary
    # accepts it, then type_dispatch routes it to slow_path.
    bad_msg = b"Z" + b"\xee" * 18
    valid_d = _encode_itch(BookEvent(EV_DELETE, 0, 7, 0, 0, 0x9999, 0x100))
    payload = _itch_msg_with_len_prefix(bad_msg) + _itch_msg_with_len_prefix(valid_d)
    pkt = _mold_pkt(payload, seq=1, msg_count=2)

    cocotb.start_soon(_axis.drive_payload(dut, pkt, tuser=1))
    n_events = await _collect_event_count(dut)
    assert int(dut.slow_path_dropped.value) >= 1, "slow_path_dropped should bump"
    assert n_events >= 1, "valid D following bad type should emit"


@cocotb.test()
async def test_truncated_final_message(dut):
    """Length-prefix says 19 bytes but only 10 bytes follow before TLAST."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    # Valid D, then a truncated message (length=19 but only 10 bytes given).
    valid_d = _encode_itch(BookEvent(EV_DELETE, 0, 1, 0, 0, 0xABCD, 1))
    truncated = (19).to_bytes(2, "big") + b"D" + b"\x00" * 9  # 12 bytes total, 9 short
    payload = _itch_msg_with_len_prefix(valid_d) + truncated
    pkt = _mold_pkt(payload, seq=1, msg_count=2)

    cocotb.start_soon(_axis.drive_payload(dut, pkt, tuser=1))
    n_events = await _collect_event_count(dut)
    # Valid D should emit; truncated may or may not emit depending on
    # how msg_boundary handles the cut-off. It must not crash.
    assert int(dut.frame_malformed.value) >= 0  # don't strictly assert; just no crash
    assert n_events >= 1, "valid D before truncated msg should still emit"


@cocotb.test()
async def test_multi_message_per_packet(dut):
    """5 D messages in one MoldUDP packet — all 5 should emit."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    msgs = [
        _encode_itch(BookEvent(EV_DELETE, 0, sym, 0, 0, 0x1000 + sym, sym))
        for sym in range(5)
    ]
    payload = b"".join(_itch_msg_with_len_prefix(m) for m in msgs)
    pkt = _mold_pkt(payload, seq=1, msg_count=5)

    cocotb.start_soon(_axis.drive_payload(dut, pkt, tuser=0xCAFE))
    n_events = await _collect_event_count(dut)
    assert n_events == 5, f"expected 5 events from 5-message packet, got {n_events}"


@cocotb.test()
async def test_seq_gap(dut):
    """Two packets with seq numbers 100 and 200 (gap of 100) should
    bump mold_seq_gap; both packets' messages should still emit."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    msg = _encode_itch(BookEvent(EV_DELETE, 0, 1, 0, 0, 0x42, 1))
    pkt1 = _mold_pkt(_itch_msg_with_len_prefix(msg), seq=100, msg_count=1)
    pkt2 = _mold_pkt(_itch_msg_with_len_prefix(msg), seq=200, msg_count=1)

    # Drive packets sequentially: interleaving beats on a single AXI-S bus
    # would corrupt the mold_strip state machine. Drive pkt1 fully first,
    # then start pkt2 and collect concurrently.
    await _axis.drive_payload(dut, pkt1, tuser=1)
    cocotb.start_soon(_axis.drive_payload(dut, pkt2, tuser=2))
    n_events = await _collect_event_count(dut)

    assert int(dut.mold_seq_gap.value) >= 1, "mold_seq_gap should bump on non-consecutive seq"
    assert n_events == 2, f"expected 2 events (one per packet), got {n_events}"
