"""Tests for sw/replay/replay.py.

Replay must:
1. Read NASDAQ historical (length-prefixed ITCH stream).
2. For each ITCH msg, emit one MoldUDP64 packet with msg_count=1, monotonic seq.
3. Pack each packet onto 64-bit AXI-S beats (8 bytes/beat, last beat has tkeep
   reflecting any short-bytes).
4. Yield (tdata, tkeep, tlast) tuples.
"""
from __future__ import annotations

from pathlib import Path

from sw.replay import replay


def _u16_be(n: int) -> bytes:
    return n.to_bytes(2, "big")


def test_one_message_one_moldudp_packet(tmp_path: Path) -> None:
    """A single 36-byte ITCH 'A' message → one MoldUDP packet with msg_count=1."""
    msg = b"A" + b"\xAB" * 35
    src = tmp_path / "in.itch"
    src.write_bytes(_u16_be(36) + msg)

    beats = list(replay.iter_beats(src))

    # MoldUDP header is 20 bytes; payload is 2-byte length + 36-byte msg = 38 bytes.
    # Total packet = 58 bytes = 7 full beats + 1 short beat (2 bytes).
    last_beats = [b for b in beats if b[2] == 1]
    assert len(last_beats) == 1, "exactly one tlast=1 beat per packet"

    # Reconstruct payload from beats (drop padding via tkeep)
    reconstructed = bytearray()
    for tdata, tkeep, _tlast in beats:
        for i in range(8):
            if tkeep & (1 << i):
                reconstructed.append((tdata >> (i * 8)) & 0xFF)
    # 20-byte MoldUDP header + 2-byte length + 36-byte msg
    assert len(reconstructed) == 20 + 2 + 36
    assert reconstructed[20:22] == _u16_be(36)
    assert bytes(reconstructed[22:]) == msg


def test_seq_monotonic(tmp_path: Path) -> None:
    """Two ITCH messages → two packets with seq 0, 1 (or any monotonic pair)."""
    src = tmp_path / "in.itch"
    src.write_bytes(_u16_be(19) + b"D" + b"\x01" * 18 +
                    _u16_be(19) + b"D" + b"\x02" * 18)

    seqs: list[int] = []
    payload = bytearray()
    for tdata, tkeep, tlast in replay.iter_beats(src):
        for i in range(8):
            if tkeep & (1 << i):
                payload.append((tdata >> (i * 8)) & 0xFF)
        if tlast:
            # MoldUDP header: 10B session + 8B seq big-endian + 2B msg_count
            seq = int.from_bytes(payload[10:18], "big")
            seqs.append(seq)
            payload.clear()

    assert seqs == sorted(seqs)
    assert len(seqs) == 2
    assert seqs[1] == seqs[0] + 1


def test_max_messages_caps_input(tmp_path: Path) -> None:
    """The max_messages parameter limits how much of the input is replayed."""
    raw = bytearray()
    for _ in range(10):
        raw += _u16_be(19) + b"D" + b"\x00" * 18
    src = tmp_path / "in.itch"
    src.write_bytes(bytes(raw))

    last_count = sum(1 for _, _, tlast in replay.iter_beats(src, max_messages=3) if tlast)
    assert last_count == 3
