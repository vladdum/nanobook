"""Filter a NASDAQ ITCH 5.0 historical file to the picked-100 stock_locates.

For M06 cosim, `lob_core`'s `sym_idx_lut` drops every event whose
`stock_locate` is not in the 100-symbol picked set (encoded in
`hw/ip/lob_core/lob_core_sym_init.mem`). Pre-filtering the slice to the
same set shrinks the cosim wallclock dramatically without changing any
observable behaviour: unpicked messages would be `sym_lut_misses` on the
RTL side and skipped on the refbook side anyway.

Output is length-prefixed ITCH (matching the historical wire format),
zstd-compressed when the destination ends in `.zst`. The output is
deterministic — same input file + same mem file produces the same bytes.

Public API:
  read_picked_locates(mem_path) -> set[int]
  filter_to_picked(src, dst, picked, max_msgs=None) -> int

Mirrors `sw/m05_tools/symbol_slice.py::filter_to_symbol` but accepts a
SET of stock_locates instead of a single one. The `_open_input` helper
from `sw/replay/replay.py` handles `.gz` / `.zst` / raw transparently.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import zstandard

from sw.refbook._itch_wire import MSG_LENGTHS
from sw.replay.replay import _open_input


REPO = Path(__file__).resolve().parents[2]
DEFAULT_SYM_INIT_MEM = REPO / "hw" / "ip" / "lob_core" / "lob_core_sym_init.mem"


def read_picked_locates(mem_path: Path) -> set[int]:
    """Read picked stock_locates from a lob_core_sym_init.mem file.

    Each line is a 2-hex-char byte where bit 7 = valid and bits 6:0 =
    sym_idx. The line index in the file equals the stock_locate value
    used in ITCH wire (Phase A's `pick_symbols.py` invariant).
    """
    picked: set[int] = set()
    for stock_locate, line in enumerate(mem_path.read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        v = int(line, 16)
        if v & 0x80:
            picked.add(stock_locate)
    return picked


def filter_to_picked(
    src_itch: Path,
    out_itch: Path,
    picked: set[int],
    max_msgs: int | None = None,
) -> int:
    """Stream a NASDAQ ITCH historical file and keep only fast-path messages
    whose stock_locate is in `picked`. Slow-path types (R/S/H/...) are
    dropped because the M03 decoder treats them as no-ops.

    Fast-path message types (`A`, `F`, `E`, `C`, `X`, `D`, `U`) all carry
    `stock_locate` at byte offset 1 in 2-byte big-endian. The parser at
    `sw/replay/itch_parser.py` confirms this layout.

    Returns the number of messages written.
    """
    out_buf = bytearray()
    captured = 0

    with _open_input(src_itch) as fp:
        while True:
            if max_msgs is not None and captured >= max_msgs:
                break
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
                continue  # slow-path; decoder ignores

            # Fast-path messages all carry stock_locate at byte 1, 2 B BE.
            stock_locate = int.from_bytes(body[1:3], "big")
            if stock_locate not in picked:
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
    p.add_argument(
        "--sym-init-mem", type=Path, default=DEFAULT_SYM_INIT_MEM,
        help="lob_core_sym_init.mem to derive the picked stock_locates from "
             "(default: hw/ip/lob_core/lob_core_sym_init.mem)",
    )
    p.add_argument(
        "--max-msgs", type=int, default=None,
        help="Optional cap on output messages (debug)",
    )
    args = p.parse_args(argv)

    picked = read_picked_locates(args.sym_init_mem)
    if not picked:
        print(f"ERROR: no picked locates in {args.sym_init_mem}", file=sys.stderr)
        return 2
    print(f"picked {len(picked)} stock_locates from {args.sym_init_mem}",
          file=sys.stderr)

    n = filter_to_picked(args.src, args.dst, picked, max_msgs=args.max_msgs)
    if n == 0:
        print("ERROR: no fast-path messages matched picked locates", file=sys.stderr)
        return 1
    size = args.dst.stat().st_size
    print(f"Filtered {n} messages from {args.src} -> {args.dst} ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
