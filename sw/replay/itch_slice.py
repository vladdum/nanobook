"""Slice the first N consecutive ITCH messages from a NASDAQ historical file.

NASDAQ TVITCH historical format: stream of `<u16-be length N><N bytes msg>`.

This tool does NOT inspect the message body. It walks the length prefixes and
copies the first N messages (header + body) byte-for-byte to the output. The
caller chooses whether to compress with zstd.
"""
from __future__ import annotations

import argparse
import gzip
import sys
from pathlib import Path
from typing import IO, cast

import zstandard


def _open_input(path: Path) -> IO[bytes]:
    """Open input transparently — gzip if .gz, raw otherwise."""
    if path.suffix == ".gz":
        # gzip.open(..., "rb") returns GzipFile, which is duck-typed binary IO
        # but isn't declared as IO[bytes] in the typeshed.
        return cast(IO[bytes], gzip.open(path, "rb"))
    return path.open("rb")


def slice_first_n(
    src: Path, dst: Path, count: int, compress: bool = True
) -> int:
    """Copy the first `count` ITCH messages from `src` to `dst`.

    Returns the number of messages actually copied (≤ count).
    """
    out_buf = bytearray()
    copied = 0
    with _open_input(src) as fp:
        while copied < count:
            hdr = fp.read(2)
            if len(hdr) < 2:
                break  # EOF
            n = int.from_bytes(hdr, "big")
            body = fp.read(n)
            if len(body) < n:
                break  # truncated
            out_buf += hdr + body
            copied += 1

    payload = bytes(out_buf)
    if compress:
        payload = zstandard.ZstdCompressor(level=10).compress(payload)
    dst.write_bytes(payload)
    return copied


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("src", type=Path, help="Input NASDAQ historical file (.gz or raw)")
    p.add_argument("dst", type=Path, help="Output slice file")
    p.add_argument("-n", "--count", type=int, default=100_000,
                   help="Number of messages to copy (default: 100000)")
    p.add_argument("--no-compress", action="store_true",
                   help="Skip zstd compression on output")
    args = p.parse_args(argv)

    n = slice_first_n(args.src, args.dst, args.count, compress=not args.no_compress)
    print(f"Sliced {n} messages from {args.src} → {args.dst}")
    return 0 if n > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
