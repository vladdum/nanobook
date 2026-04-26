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
