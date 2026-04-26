"""End-to-end byte-exact gate for the full itch_decoder chain.

Drives one MoldUDP64 packet per ITCH event through all 6 pipeline stages;
compares the emitted book_event_t stream byte-for-byte against
generate_book_events() + pack().

Design note: the RTL uses s_tuser (packet-level AXI-S TUSER) for ingress_ts
in each BookEvent, not the timestamp embedded in the ITCH message body.
To achieve a byte-exact match with generate_book_events(), each synthetic
event is therefore sent in its own single-message MoldUDP64 packet, with
the packet's TUSER set to the expected ingress_ts for that event.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import _axis
from synthetic_gen import generate_book_events, _encode_itch


def _mold_pkt(itch_msg: bytes, *, seq: int = 1, ingress_ts: int = 0) -> bytes:
    """Wrap a single ITCH message body in a MoldUDP64 packet.

    MoldUDP64 header: session[10B] + sequence[8B BE] + msg_count[2B BE].
    Each message is preceded by its 2-byte BE length (as msg_boundary requires).
    TUSER carries the packet ingress_ts.
    """
    msg_with_len = len(itch_msg).to_bytes(2, "big") + itch_msg
    header = b"NSDQ123456" + seq.to_bytes(8, "big") + (1).to_bytes(2, "big")
    return header + msg_with_len


async def _collect_n_events(dut, n: int, *, max_cycles: int = 5_000_000) -> bytes:
    """Read n event beats from the output (32 bytes each, TLAST=1 per beat)."""
    out = bytearray()
    dut.m_tready.value = 1
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value):
            beat = int(dut.m_tdata.value).to_bytes(32, "little")
            out.extend(beat)
            if len(out) >= n * 32:
                return bytes(out[:n * 32])
    raise TimeoutError(f"only got {len(out)//32} events; expected {n}")


async def _drive_events(dut, seed: int, n_symbols: int, n_events: int) -> None:
    """Drive all events as individual MoldUDP64 packets with correct TUSER."""
    for seq, ev in enumerate(generate_book_events(seed, n_symbols, n_events), start=1):
        itch_msg = _encode_itch(ev)
        pkt = _mold_pkt(itch_msg, seq=seq, ingress_ts=ev.ingress_ts)
        await _axis.drive_payload(dut, pkt, tuser=ev.ingress_ts)


@cocotb.test()
async def test_byte_exact_smoke_100_events(dut):
    """Smoke: 100 events. Must pass before scaling up."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    seed, n_symbols, n_events = 42, 100, 100
    expected = b"".join(e.pack() for e in generate_book_events(seed, n_symbols, n_events))

    cocotb.start_soon(_drive_events(dut, seed, n_symbols, n_events))

    actual = await _collect_n_events(dut, n_events)
    assert actual == expected, (
        f"byte-exact mismatch at first diff byte "
        f"{next((i for i in range(min(len(actual), len(expected))) if actual[i] != expected[i]), -1)}"
    )


@cocotb.test()
async def test_byte_exact_10k_events(dut):
    """Full 10K-event run. Run only after smoke passes."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())
    await _axis.reset(dut)

    seed, n_symbols, n_events = 42, 100, 10_000
    expected = b"".join(e.pack() for e in generate_book_events(seed, n_symbols, n_events))

    cocotb.start_soon(_drive_events(dut, seed, n_symbols, n_events))

    actual = await _collect_n_events(dut, n_events, max_cycles=20_000_000)
    assert actual == expected, "byte-exact mismatch in 10K-event stream"
