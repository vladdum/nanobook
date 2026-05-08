"""Replay NASDAQ historical ITCH 5.0 file into MoldUDP64 packets, AXI-S 64-bit.

Wire format:
  - NASDAQ historical: <u16-be length N><N bytes ITCH msg>
  - MoldUDP64 packet: 10B session + 8B seq (BE) + 2B msg_count (BE) + payload
    where payload is <u16-be length><N bytes msg>... for `msg_count` messages.

This tool emits one ITCH message per MoldUDP packet (msg_count = 1, monotonic
seq from 0). Justification: M03's tb_msg_boundary covers multi-msg packets via
fuzz; M04's value is wire-byte coverage, not boundary stress.

AXI-S framing:
  - 64-bit data, little-endian byte 0 in TDATA[7:0]
  - tkeep bit i corresponds to byte i (i.e., bit 0 is the LSB byte)
  - tlast asserted on the final beat of each MoldUDP packet
"""
from __future__ import annotations

import argparse
import gzip
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import IO, cast

import zstandard

# 10 bytes of dummy session id
_SESSION = b"NANO000001"
assert len(_SESSION) == 10, "MoldUDP64 session id must be exactly 10 bytes"


def _open_input(path: Path) -> IO[bytes]:
    """Open input transparently — gzip if .gz, zstd if .zst, raw otherwise."""
    if path.suffix == ".gz":
        # gzip.GzipFile is duck-typed binary IO but isn't IO[bytes] in typeshed.
        return cast(IO[bytes], gzip.open(path, "rb"))
    if path.suffix == ".zst":
        return cast(IO[bytes], zstandard.ZstdDecompressor().stream_reader(path.open("rb")))
    return path.open("rb")


def iter_packet_bytes(src: Path, max_messages: int | None = None) -> Iterator[bytes]:
    """Yield raw MoldUDP64 packet bytes — one ITCH message per packet."""
    seq = 0
    with _open_input(src) as fp:
        while True:
            if max_messages is not None and seq >= max_messages:
                return
            hdr = fp.read(2)
            if len(hdr) < 2:
                return
            n = int.from_bytes(hdr, "big")
            body = fp.read(n)
            if len(body) < n:
                return
            payload = hdr + body  # <u16-be length><msg>
            packet = (
                _SESSION
                + seq.to_bytes(8, "big")
                + (1).to_bytes(2, "big")
                + payload
            )
            yield packet
            seq += 1


def iter_beats(
    src: Path, max_messages: int | None = None
) -> Iterator[tuple[int, int, int]]:
    """Yield (tdata, tkeep, tlast) tuples for cocotb to drive into the decoder.

    tdata is a 64-bit unsigned int (byte 0 in low 8 bits).
    tkeep is an 8-bit bitmask (bit i set if byte i is valid).
    tlast is 0 or 1; asserted on the final beat of each MoldUDP packet.
    """
    for packet in iter_packet_bytes(src, max_messages=max_messages):
        n_full_beats, rem = divmod(len(packet), 8)
        for b in range(n_full_beats):
            chunk = packet[b * 8:(b + 1) * 8]
            tdata = int.from_bytes(chunk, "little")
            tkeep = 0xFF
            tlast = 1 if (b == n_full_beats - 1 and rem == 0) else 0
            yield (tdata, tkeep, tlast)
        if rem > 0:
            chunk = packet[n_full_beats * 8:].ljust(8, b"\x00")
            tdata = int.from_bytes(chunk, "little")
            tkeep = (1 << rem) - 1
            yield (tdata, tkeep, 1)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", type=Path)
    p.add_argument("-n", "--max-messages", type=int, default=None)
    p.add_argument("--dump", action="store_true",
                   help="Dump first 16 beats as hex for debugging")
    args = p.parse_args(argv)

    if args.dump:
        for i, (tdata, tkeep, tlast) in enumerate(iter_beats(args.src, args.max_messages)):
            if i >= 16:
                break
            print(f"  beat {i:3d}: tdata=0x{tdata:016X} tkeep=0x{tkeep:02X} tlast={tlast}")
        return 0

    count = sum(1 for _ in iter_beats(args.src, args.max_messages))
    print(f"Replayed {count} beats from {args.src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
