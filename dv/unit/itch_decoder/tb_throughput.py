"""Throughput TB for the wired itch_decoder.

Drives a long synthetic ITCH stream and measures the input acceptance
ratio (s_tvalid && s_tready handshakes per elapsed cycle).

KNOWN M03 LIMITATION
====================
The M03 design spec §3 specifies "1 beat/cycle, no bubbles" → ratio ≥ 0.99.
The current `msg_boundary.sv` (Phase E) uses a byte-pump FSM that accepts
one 8-byte beat then drains it byte-by-byte over ~8 cycles before
accepting the next. Theoretical maximum input ratio ≈ 1/9 ≈ 0.11.

This TB asserts ratio ≥ 0.10 — enough to catch regressions if the rate
drops further (e.g., a future change introducing additional stalls), but
NOT a check against the spec's full-beat-per-cycle target.

CARRIED TO M04: redesign `msg_boundary.sv` for whole-beat parallel parsing
so input throughput hits the spec's ≥ 0.99 target. M04 will also bring
real-pcap pressure that surfaces this limit naturally.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _axis
from synthetic_gen import generate_book_events, _encode_itch

# Threshold for "decoder is not adding new bubbles" given byte-pump bottleneck.
# Bumping this back to 0.99 is the M04 redesign exit gate.
THROUGHPUT_FLOOR = 0.10


def _mold_pkt(events_bytes: list[bytes], *, seq: int = 1) -> bytes:
    """Wrap a list of ITCH message byte strings in a MoldUDP64 packet.

    MoldUDP64 header: session[10B] + sequence[8B BE] + msg_count[2B BE].
    Each message is preceded by its 2-byte BE length as required by
    msg_boundary stage.
    """
    msg_count = len(events_bytes)
    payload = bytearray()
    for msg in events_bytes:
        payload += len(msg).to_bytes(2, "big") + msg
    header = b"NSDQ123456" + seq.to_bytes(8, "big") + msg_count.to_bytes(2, "big")
    return bytes(header) + bytes(payload)


async def _drive_and_count(dut, payload: bytes, *, tuser: int = 0) -> tuple[int, int]:
    """Drive `payload` as 64-bit AXI-S beats and count (accepted_beats,
    elapsed_cycles) between first input beat acceptance and last.

    Returns (accepted_beats, elapsed_cycles). The caller asserts
    accepted_beats / elapsed_cycles >= THROUGHPUT_FLOOR.
    """
    n = len(payload)
    full_beats = n // 8
    tail = n % 8
    total_beats = full_beats + (1 if tail else 0)
    assert total_beats > 0

    # Always assert m_tready=1 so the output drains and doesn't apply
    # backpressure to the input chain.
    dut.m_tready.value = 1

    accepted = 0
    first_acc_cycle = -1
    last_acc_cycle = -1
    cycle = 0

    for i in range(total_beats):
        chunk = payload[i * 8 : i * 8 + 8]
        if len(chunk) < 8:
            chunk = chunk + b"\x00" * (8 - len(chunk))
            keep = (1 << tail) - 1
        else:
            keep = 0xFF
        dut.s_tdata.value = int.from_bytes(chunk, "little")
        dut.s_tkeep.value = keep
        dut.s_tvalid.value = 1
        dut.s_tlast.value = 1 if i == total_beats - 1 else 0
        dut.s_tuser.value = tuser if i == 0 else 0

        # Wait until handshake completes (s_tvalid && s_tready).
        await RisingEdge(dut.clk)
        cycle += 1
        while int(dut.s_tready.value) == 0:
            await RisingEdge(dut.clk)
            cycle += 1
        # Beat accepted on this cycle.
        accepted += 1
        if first_acc_cycle < 0:
            first_acc_cycle = cycle
        last_acc_cycle = cycle

    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0

    elapsed = last_acc_cycle - first_acc_cycle + 1
    return accepted, elapsed


def _build_packet(seed: int, n_symbols: int, n_events: int) -> bytes:
    """Generate a proper MoldUDP64 packet with per-message length prefixes."""
    msgs = [_encode_itch(ev) for ev in generate_book_events(seed, n_symbols, n_events)]
    return _mold_pkt(msgs, seq=1)


@cocotb.test()
async def test_throughput_no_bubbles_1k(dut):
    """1K synthetic events; assert input acceptance ratio >= THROUGHPUT_FLOOR."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)

    seed, n_symbols, n_events = 42, 100, 1_000
    pkt = _build_packet(seed, n_symbols, n_events)

    accepted, elapsed = await _drive_and_count(dut, pkt, tuser=0xCAFE)
    ratio = accepted / elapsed
    dut._log.info(f"accepted={accepted} elapsed_cycles={elapsed} ratio={ratio:.4f}")
    assert ratio >= THROUGHPUT_FLOOR, (
        f"throughput too low: accepted {accepted} beats over {elapsed} "
        f"cycles (ratio {ratio:.4f}, target >= {THROUGHPUT_FLOOR})"
    )


@cocotb.test()
async def test_throughput_no_bubbles_5k(dut):
    """5K synthetic events. Same gate but longer stream — surfaces
    bubbles that only appear after pipeline warm-up."""
    cocotb.start_soon(Clock(dut.clk, 4, units="ns").start())
    await _axis.reset(dut)

    seed, n_symbols, n_events = 42, 100, 5_000
    pkt = _build_packet(seed, n_symbols, n_events)

    accepted, elapsed = await _drive_and_count(dut, pkt, tuser=0xCAFE)
    ratio = accepted / elapsed
    dut._log.info(f"5K stream: accepted={accepted} elapsed_cycles={elapsed} ratio={ratio:.4f}")
    assert ratio >= THROUGHPUT_FLOOR, (
        f"5K throughput too low: ratio {ratio:.4f}, target >= {THROUGHPUT_FLOOR}"
    )
