"""TB for hw/ip/itch_decoder/mold_strip.sv.

Drives MoldUDP64-wrapped payloads on the input AXI-S; expects the 20-byte
header stripped on the output and seq-gap counter to bump on out-of-order
sequence numbers.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock

import _axis


def _mold_packet(seq: int, msg_count: int, payload: bytes) -> bytes:
    """Construct a MoldUDP64 packet: 10B session + 8B seq + 2B msg_count + payload."""
    session = b"NSDQ123456"  # 10 ASCII bytes
    return session + seq.to_bytes(8, "big") + msg_count.to_bytes(2, "big") + payload


@cocotb.test()
async def test_strip_single_packet(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)
    payload = b"\x00\x01" + b"A" + b"\x11" * 33  # 2B length-prefix + ITCH A
    pkt = _mold_packet(seq=1, msg_count=1, payload=payload)
    drive = cocotb.start_soon(_axis.drive_payload(dut, pkt, tuser=0xDEADBEEF))
    out, tuser = await _axis.collect_output_payload(dut)
    await drive
    assert out == payload, f"got {out.hex()}, expected {payload.hex()}"
    assert tuser == 0xDEADBEEF, "ingress_ts should propagate from first input beat"
    assert int(dut.mold_seq_gap.value) == 0, "no gap on a single packet"


@cocotb.test()
async def test_strip_seq_continues(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)

    pkt1 = _mold_packet(seq=10, msg_count=1, payload=b"\x00\x01D" + b"\x11" * 16)
    pkt2 = _mold_packet(seq=11, msg_count=1, payload=b"\x00\x01D" + b"\x11" * 16)
    drive1 = cocotb.start_soon(_axis.drive_payload(dut, pkt1, tuser=1))
    out1, _ = await _axis.collect_output_payload(dut)
    await drive1
    assert out1 == b"\x00\x01D" + b"\x11" * 16
    drive2 = cocotb.start_soon(_axis.drive_payload(dut, pkt2, tuser=2))
    out2, _ = await _axis.collect_output_payload(dut)
    await drive2
    assert out2 == b"\x00\x01D" + b"\x11" * 16
    assert int(dut.mold_seq_gap.value) == 0, "consecutive seqs should not bump gap"


@cocotb.test()
async def test_strip_seq_jump_bumps_counter(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)

    pkt1 = _mold_packet(seq=100, msg_count=1, payload=b"\x00\x01D" + b"\x11" * 16)
    pkt2 = _mold_packet(seq=200, msg_count=1, payload=b"\x00\x01D" + b"\x11" * 16)
    drive1 = cocotb.start_soon(_axis.drive_payload(dut, pkt1, tuser=1))
    _ = await _axis.collect_output_payload(dut)
    await drive1
    drive2 = cocotb.start_soon(_axis.drive_payload(dut, pkt2, tuser=2))
    _ = await _axis.collect_output_payload(dut)
    await drive2
    assert int(dut.mold_seq_gap.value) == 1, "seq jump should bump gap counter"
