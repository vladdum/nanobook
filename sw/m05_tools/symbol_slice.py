"""Slice a target-symbol-anchored fast-path window from a NASDAQ ITCH file.

For M05 cosim, we need a slice that begins at (or near) the first fast-path
ITCH message touching the chosen `SYMBOL_FILTER_ID`, and continues for a
configurable number of subsequent messages (across all symbols — lob_core's
own `SYMBOL_FILTER_ID` parameter handles the per-symbol selection).

NASDAQ historical wire format: stream of `<u16-be length N><N bytes msg>`.
We do NOT inspect MoldUDP framing — historical files are pure ITCH with
length prefix, not MoldUDP. The cosim's `replay.iter_beats` re-frames into
MoldUDP for AXI-S input on the way to the decoder.

Detection strategy:
  - Walk length-prefixed records.
  - Decode with `sw.replay.itch_parser.parse_one(msg)`.
  - First fast-path BookEvent whose `symbol_id == target` is the anchor.
  - From the anchor message inclusive, capture the next `n_msgs` messages
    (length-prefixed, byte-for-byte).

Output is length-prefixed ITCH (matching the historical wire format), NOT
MoldUDP-framed. Compresses with zstd when the destination ends in `.zst`.

Public API:
  slice_to_symbol_fastpath(src, dst, symbol_id, n_msgs) -> int
    returns the number of messages actually written (<= n_msgs).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import zstandard

from sw.refbook._itch_wire import MSG_LENGTHS
from sw.replay.itch_parser import parse_one
# Use replay._open_input (handles .gz / .zst / raw) — itch_slice's variant
# only handles .gz, but the M04 100K committed slices are .zst so we need
# the broader opener.
from sw.replay.replay import _open_input


def _slow_path_length(type_byte: bytes) -> int:
    """Best-effort slow-path length lookup.

    NASDAQ ITCH 5.0 has many slow-path types; for M05 we only need to
    know how many bytes to skip. The historical wire format already
    length-prefixes every record, so we don't actually need this — we
    simply read the prefix and advance. Kept as a documentation comment.
    """
    raise NotImplementedError(
        "slow-path length lookup not used; length prefix is authoritative"
    )


def slice_to_symbol_fastpath(
    src_itch: Path,
    out_itch: Path,
    symbol_id: int,
    n_msgs: int,
) -> int:
    """Find the first fast-path ITCH message matching `symbol_id`, then
    capture the next `n_msgs` messages (across all symbols) starting at
    that anchor inclusive.

    Returns the number of messages written.
    """
    if n_msgs <= 0:
        raise ValueError(f"n_msgs must be > 0, got {n_msgs}")

    out_buf = bytearray()
    captured = 0
    anchor_found = False

    with _open_input(src_itch) as fp:
        while captured < n_msgs:
            hdr = fp.read(2)
            if len(hdr) < 2:
                break  # EOF
            n = int.from_bytes(hdr, "big")
            if n == 0:
                # Defensive: zero-length record — skip gracefully.
                continue
            body = fp.read(n)
            if len(body) < n:
                break  # truncated

            if not anchor_found:
                type_byte = body[0:1]
                if type_byte not in MSG_LENGTHS:
                    # Slow-path message — ignore for anchor detection.
                    continue
                ev = parse_one(body)
                if ev is None or ev.symbol_id != symbol_id:
                    continue
                anchor_found = True

            out_buf += hdr + body
            captured += 1

    payload = bytes(out_buf)
    if out_itch.suffix == ".zst":
        payload = zstandard.ZstdCompressor(level=10).compress(payload)
    out_itch.parent.mkdir(parents=True, exist_ok=True)
    out_itch.write_bytes(payload)
    return captured


def filter_to_symbol(
    src_itch: Path,
    out_itch: Path,
    symbol_id: int,
) -> int:
    """Stream a raw NASDAQ ITCH file and keep only fast-path messages for
    the target symbol_id. Slow-path types (R/S/H/etc.) are dropped — the
    M03 decoder treats them as no-ops anyway. Unknown types are also
    dropped. Output is length-prefixed ITCH (zstd if dst ends in .zst).

    Used by Phase J full-day cosim: the unfiltered 03272019 file has
    ~10M messages (~3 hr cocotb wallclock); filtering to symbol 5754
    drops it to ~25K messages (~30 s wallclock) without changing the
    set of TOB deltas the cosim observes (lob_core's symbol filter
    would have dropped the others anyway).

    Returns the number of messages written.
    """
    out_buf = bytearray()
    captured = 0

    with _open_input(src_itch) as fp:
        while True:
            hdr = fp.read(2)
            if len(hdr) < 2:
                break
            n = int.from_bytes(hdr, "big")
            if n == 0:
                continue
            body = fp.read(n)
            if len(body) < n:
                break

            type_byte = body[0:1]
            if type_byte not in MSG_LENGTHS:
                continue   # slow-path; decoder ignores
            ev = parse_one(body)
            if ev is None or ev.symbol_id != symbol_id:
                continue
            out_buf += hdr + body
            captured += 1

    payload = bytes(out_buf)
    if out_itch.suffix == ".zst":
        payload = zstandard.ZstdCompressor(level=10).compress(payload)
    out_itch.parent.mkdir(parents=True, exist_ok=True)
    out_itch.write_bytes(payload)
    return captured


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", type=Path, help="Source NASDAQ ITCH file (.gz / .zst / raw)")
    p.add_argument("dst", type=Path, help="Output file (.zst suffix triggers compression)")
    p.add_argument("--symbol", type=int, required=True,
                   help="Target stock_locate / symbol_id (e.g., 5754)")
    p.add_argument("--n", type=int, default=None,
                   help="Number of messages to capture from anchor inclusive "
                        "(slice mode). Mutually exclusive with --filter-only.")
    p.add_argument("--filter-only", action="store_true",
                   help="Keep ONLY fast-path messages for the target symbol "
                        "(used by Phase J full-day cosim). Wallclock wins are "
                        "~100x vs an unfiltered 10M-msg replay.")
    args = p.parse_args(argv)

    if args.filter_only:
        if args.n is not None:
            print("ERROR: --n and --filter-only are mutually exclusive", file=sys.stderr)
            return 2
        n = filter_to_symbol(args.src, args.dst, args.symbol)
        if n == 0:
            print(f"ERROR: no fast-path message found for symbol_id={args.symbol}",
                  file=sys.stderr)
            return 1
        size = args.dst.stat().st_size
        print(f"Filtered {n} messages from {args.src} -> {args.dst} ({size} bytes)")
        return 0

    if args.n is None:
        print("ERROR: --n required (or use --filter-only for full-day filter mode)",
              file=sys.stderr)
        return 2
    n = slice_to_symbol_fastpath(args.src, args.dst, args.symbol, args.n)
    if n == 0:
        print(f"ERROR: no fast-path message found for symbol_id={args.symbol}",
              file=sys.stderr)
        return 1
    size = args.dst.stat().st_size
    print(f"Sliced {n} messages from {args.src} -> {args.dst} ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
