"""TB for hw/ip/itch_decoder/msg_boundary.sv.

Drives raw ITCH-message-stream payload (no MoldUDP wrapper — that's the
previous stage's job); expects the output to emit one TLAST-bounded frame
per ITCH message.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock

import _axis


def _msg(type_byte: bytes, body: bytes) -> bytes:
    """One ITCH message with 2B length prefix (length = type+body)."""
    msg = type_byte + body
    return len(msg).to_bytes(2, "big") + msg


@cocotb.test()
async def test_single_message(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)
    msg = _msg(b"D", b"\x00" * 18)  # ITCH D = 19 bytes
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=0xCAFE))
    out, tuser = await _axis.collect_output_payload(dut)
    await drive
    assert out == b"D" + b"\x00" * 18, f"unexpected output: {out.hex()}"
    assert tuser == 0xCAFE
    assert int(dut.frame_malformed.value) == 0


@cocotb.test()
async def test_two_messages_one_packet(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)
    payload = _msg(b"D", b"\x00" * 18) + _msg(b"D", b"\x11" * 18)
    drive = cocotb.start_soon(_axis.drive_payload(dut, payload, tuser=1))
    out1, _ = await _axis.collect_output_payload(dut)
    out2, _ = await _axis.collect_output_payload(dut)
    await drive
    assert out1 == b"D" + b"\x00" * 18
    assert out2 == b"D" + b"\x11" * 18


@cocotb.test()
async def test_zero_length_bumps_malformed(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)
    # Length = 0 → malformed.
    payload = b"\x00\x00" + _msg(b"D", b"\x00" * 18)
    drive = cocotb.start_soon(_axis.drive_payload(dut, payload, tuser=1))
    out, _ = await _axis.collect_output_payload(dut)
    await drive
    assert out == b"D" + b"\x00" * 18, "valid msg following malformed should still emit"
    assert int(dut.frame_malformed.value) == 1


@cocotb.test()
async def test_message_spans_packet_boundary(dut):
    """A message that straddles the 8-byte beat boundary (typical case
    for ITCH 5.0 messages — most lengths aren't multiples of 8)."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)
    # ITCH A is 36 bytes; 2+36 = 38 bytes total — spans 5 beats.
    msg = _msg(b"A", b"\x00" * 35)
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=42))
    out, _ = await _axis.collect_output_payload(dut)
    await drive
    assert out == b"A" + b"\x00" * 35, f"len={len(out)}, hex={out.hex()}"
