"""TB for hw/ip/itch_decoder/type_dispatch.sv.

Drives one ITCH-message-aligned AXI-S frame per test (no MoldUDP, no length
prefix — that's earlier stages). Asserts the right dispatch lane fires and
forwards the message body unchanged.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _axis


async def _drive_and_capture(dut, msg: bytes, lane: str, *, tuser: int = 0):
    """Drive `msg` on input; collect on the named dispatch lane.

    `lane` is one of: add, exec, cancel, delete, replace, slow.
    Returns (collected_bytes, captured_tuser).
    """
    # All dispatch lanes have m_tready signals; assert m_tready=1 on the
    # expected lane so the DUT's s_tready (which it gates on the active
    # m_tready) goes high. Other lanes' m_tready are tied 0 — they
    # shouldn't fire anyway.
    for n in ("add", "exec", "cancel", "delete", "replace", "slow"):
        getattr(dut, f"dispatch_{n}_tready").value = (1 if n == lane else 0)

    # Concurrent dispatch: drive input, collect output.
    drive = cocotb.start_soon(_axis.drive_payload(dut, msg, tuser=tuser))

    # Inline collect on the named lane (mirrors _axis.collect_output_payload
    # but for the dispatch_<lane>_* signal names).
    payload = bytearray()
    captured_tuser = 0
    first = True
    for _ in range(1024):
        await RisingEdge(dut.clk)
        if int(getattr(dut, f"dispatch_{lane}_tvalid").value):
            beat = int(getattr(dut, f"dispatch_{lane}_tdata").value).to_bytes(8, "little")
            tkeep = int(getattr(dut, f"dispatch_{lane}_tkeep").value)
            n = bin(tkeep).count("1")
            payload.extend(beat[:n])
            if first:
                captured_tuser = int(getattr(dut, f"dispatch_{lane}_tuser").value)
                first = False
            if int(getattr(dut, f"dispatch_{lane}_tlast").value):
                await drive
                return bytes(payload), captured_tuser
    raise TimeoutError(f"no TLAST on dispatch_{lane}_* within 1024 cycles")


async def _reset(dut):
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0
    dut.s_tuser.value  = 0
    for n in ("add", "exec", "cancel", "delete", "replace", "slow"):
        getattr(dut, f"dispatch_{n}_tready").value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_dispatch_add_A(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"A" + b"\x11" * 35  # ITCH A = 36 bytes
    out, tuser = await _drive_and_capture(dut, msg, "add", tuser=0xAAA1)
    assert out == msg, f"add lane should forward unchanged, got {out.hex()}"
    assert tuser == 0xAAA1


@cocotb.test()
async def test_dispatch_add_F(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"F" + b"\x22" * 39  # ITCH F = 40 bytes (Add Order with MPID)
    out, _ = await _drive_and_capture(dut, msg, "add")
    assert out == msg


@cocotb.test()
async def test_dispatch_exec_E(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"E" + b"\x33" * 30  # ITCH E = 31 bytes
    out, _ = await _drive_and_capture(dut, msg, "exec")
    assert out == msg


@cocotb.test()
async def test_dispatch_exec_C(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"C" + b"\x44" * 35  # ITCH C = 36 bytes
    out, _ = await _drive_and_capture(dut, msg, "exec")
    assert out == msg


@cocotb.test()
async def test_dispatch_cancel(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"X" + b"\x55" * 22  # ITCH X = 23 bytes
    out, _ = await _drive_and_capture(dut, msg, "cancel")
    assert out == msg


@cocotb.test()
async def test_dispatch_delete(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"D" + b"\x66" * 18  # ITCH D = 19 bytes
    out, _ = await _drive_and_capture(dut, msg, "delete")
    assert out == msg


@cocotb.test()
async def test_dispatch_replace(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"U" + b"\x77" * 34  # ITCH U = 35 bytes
    out, _ = await _drive_and_capture(dut, msg, "replace")
    assert out == msg


@cocotb.test()
async def test_dispatch_slow_R(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    msg = b"R" + b"\xff" * 38  # ITCH R = 39 bytes (slow path)
    out, _ = await _drive_and_capture(dut, msg, "slow")
    assert out == msg
    assert int(dut.slow_path_dropped.value) == 1, "slow counter should bump"


@cocotb.test()
async def test_dispatch_slow_unknown(dut):
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    # Type 'Z' (0x5A) — not in any fast-path. Length doesn't matter for this
    # test; we just need the type byte to land at offset 0.
    msg = b"Z" + b"\xee" * 10
    out, _ = await _drive_and_capture(dut, msg, "slow")
    assert out == msg
    assert int(dut.slow_path_dropped.value) == 1


@cocotb.test()
async def test_back_to_back_two_messages(dut):
    """A then D, drive both, assert each lands on its lane and nothing else."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _reset(dut)
    a = b"A" + b"\x11" * 35
    d = b"D" + b"\x66" * 18
    out_a, _ = await _drive_and_capture(dut, a, "add", tuser=1)
    assert out_a == a
    out_d, _ = await _drive_and_capture(dut, d, "delete", tuser=2)
    assert out_d == d
