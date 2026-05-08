"""Tiny AXI-S driver/monitor helpers for itch_decoder cocotb TBs.

Keep these MINIMAL — cocotbext-axi exists, but for one-byte-aligned 64-bit
AXI-S streams a dependency is overkill. If something here grows beyond
~50 lines, we should reconsider.
"""
from __future__ import annotations

from cocotb.triggers import RisingEdge


async def drive_payload(dut, payload: bytes, *, tuser: int = 0,
                        idle_cycles: int = 0) -> None:
    """Send `payload` as 64-bit AXI-S beats. Holds TUSER on the first beat
    (matches how MAC-RX presents ingress_ts upstream)."""
    n = len(payload)
    full_beats = n // 8
    tail_bytes = n % 8
    total_beats = full_beats + (1 if tail_bytes else 0)
    assert total_beats > 0, "drive_payload called with empty payload"

    for i in range(total_beats):
        # Optional idle gap between packets / inside packets.
        for _ in range(idle_cycles):
            dut.s_tvalid.value = 0
            await RisingEdge(dut.clk)

        chunk = payload[i*8 : i*8 + 8]
        if len(chunk) < 8:
            chunk = chunk + b"\x00" * (8 - len(chunk))
            tkeep = (1 << tail_bytes) - 1
        else:
            tkeep = 0xFF
        dut.s_tdata.value  = int.from_bytes(chunk, "little")
        dut.s_tkeep.value  = tkeep
        dut.s_tvalid.value = 1
        dut.s_tlast.value  = 1 if i == total_beats - 1 else 0
        dut.s_tuser.value  = tuser if i == 0 else 0
        await RisingEdge(dut.clk)
        # Wait for handshake completion
        while int(dut.s_tready.value) == 0:
            await RisingEdge(dut.clk)

    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0


async def collect_output_payload(dut, *, max_cycles: int = 1024) -> tuple[bytes, int]:
    """Read whatever the DUT emits on its `m_*` AXI-S until TLAST. Returns
    (payload, tuser_first_beat)."""
    payload = bytearray()
    tuser_first = 0
    first = True
    for _ in range(max_cycles):
        dut.m_tready.value = 1
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value):
            beat = int(dut.m_tdata.value).to_bytes(8, "little")
            tkeep = int(dut.m_tkeep.value) if hasattr(dut, "m_tkeep") else 0xFF
            n = bin(tkeep).count("1")
            payload.extend(beat[:n])
            if first:
                tuser_first = int(dut.m_tuser.value) if hasattr(dut, "m_tuser") else 0
                first = False
            if int(dut.m_tlast.value):
                dut.m_tready.value = 0
                return bytes(payload), tuser_first
    raise TimeoutError("no TLAST observed within max_cycles")


async def reset(dut, *, cycles: int = 4) -> None:
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0
    dut.s_tuser.value  = 0
    dut.m_tready.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


# ─── M04 cosim helpers ───────────────────────────────────────────────────────────


async def drive_beats(dut, beats) -> None:
    """Drive a sequence of pre-framed (tdata, tkeep, tlast) tuples into the
    decoder's AXI-S input. Used by M04 cosim, where MoldUDP framing is built
    upstream by sw.replay.replay.iter_beats.

    Matches drive_payload's pattern: sample s_tready after RisingEdge in the
    writable phase. Do NOT `await ReadOnly()` here — leaving the loop body in
    ReadOnly would block the next iteration's signal writes ("Attempting
    settings a value during the ReadOnly phase" in cocotb 2.0).
    """
    for tdata, tkeep, tlast in beats:
        dut.s_tdata.value  = tdata
        dut.s_tkeep.value  = tkeep
        dut.s_tlast.value  = tlast
        dut.s_tuser.value  = 0  # ingress_ts unused for M04 wire-correctness
        dut.s_tvalid.value = 1
        await RisingEdge(dut.clk)
        # Backpressure: wait for the cycle in which s_tready is high.
        while int(dut.s_tready.value) == 0:
            await RisingEdge(dut.clk)
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0


async def capture_book_events(dut, into) -> None:
    """Capture every accepted m_* beat as a 32-byte BookEvent record.

    The decoder emits one event per beat (m_tdata is 256 bits = 32 B), so
    every (m_tvalid && m_tready) handshake yields one record. m_tlast is
    asserted on every beat in this configuration.
    """
    from cocotb.triggers import ReadOnly
    from sw.refbook.synthetic_gen import BookEvent

    dut.m_tready.value = 1
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_tvalid.value) and int(dut.m_tready.value):
            data = int(dut.m_tdata.value)
            ev = BookEvent(
                type=data & 0xFF,
                side=(data >> 8) & 0xFF,
                symbol_id=(data >> 16) & 0xFFFF,
                price=(data >> 32) & 0xFFFFFFFF,
                shares=(data >> 64) & 0xFFFFFFFF,
                # bits 96..127 = _pad (skipped — not on dataclass)
                order_id=(data >> 128) & 0xFFFFFFFFFFFFFFFF,
                ingress_ts=(data >> 192) & 0xFFFFFFFFFFFFFFFF,
            )
            into.append(ev)
