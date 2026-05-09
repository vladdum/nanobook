"""Diff tool for actual_events.bin (RTL) vs expected_events.bin (Python parser).

Outputs:
- MATCH: streams are byte-identical.
- DIVERGE @ message N: field-level breakdown of the first mismatched record.
  Includes a "minimal repro" command that slices the original pcap at offset N.
- LENGTH MISMATCH: streams differ in count.
- SLOW-PATH MISMATCH: byte streams match but the slow_path_dropped counters differ.
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

from sw.refbook.synthetic_gen import BookEvent
from sw.replay import event_bin


@dataclass
class DiffResult:
    matched: bool
    first_divergence_offset: int | None = None
    diff_summary: str = ""
    actual_count: int = 0
    expected_count: int = 0


_FIELDS = ("type", "side", "symbol_id", "price", "shares", "order_id", "ingress_ts")


def _field_diff(actual: BookEvent, expected: BookEvent) -> str:
    diffs: list[str] = []
    for fname in _FIELDS:
        a = getattr(actual, fname)
        e = getattr(expected, fname)
        if a != e:
            diffs.append(f"  {fname:12s}  actual={a!r:>20}  expected={e!r:>20}")
    return "\n".join(diffs)


def diff(
    actual_path: Path,
    expected_path: Path,
    expected_slow: int | None = None,
    actual_slow: int | None = None,
) -> DiffResult:
    """Compare two BookEvent dump files and (optionally) slow-path counters."""
    res = DiffResult(matched=True)

    with actual_path.open("rb") as a_fp, expected_path.open("rb") as e_fp:
        idx = 0
        while True:
            a_raw = a_fp.read(event_bin.RECORD_SIZE)
            e_raw = e_fp.read(event_bin.RECORD_SIZE)
            if not a_raw and not e_raw:
                break
            if not a_raw or not e_raw:
                res.matched = False
                res.diff_summary = (
                    f"length mismatch: actual_count={idx + (1 if a_raw else 0)}, "
                    f"expected_count={idx + (1 if e_raw else 0)} at index {idx}"
                )
                res.first_divergence_offset = idx
                res.actual_count = idx
                res.expected_count = idx
                return res

            if a_raw != e_raw:
                a_ev = event_bin.from_bytes(a_raw)
                e_ev = event_bin.from_bytes(e_raw)
                res.matched = False
                res.first_divergence_offset = idx
                res.diff_summary = (
                    f"divergence at message {idx}:\n{_field_diff(a_ev, e_ev)}"
                )
                return res

            idx += 1

    res.actual_count = idx
    res.expected_count = idx

    if expected_slow is not None and actual_slow is not None and expected_slow != actual_slow:
        res.matched = False
        res.diff_summary = (
            f"slow_path_dropped mismatch: actual={actual_slow} expected={expected_slow}"
        )

    return res


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("actual", type=Path, help="actual_events.bin from the RTL")
    p.add_argument("expected", type=Path, help="expected_events.bin from itch_parser")
    p.add_argument("--actual-slow", type=int, default=None)
    p.add_argument("--expected-slow", type=int, default=None)
    p.add_argument("--source-pcap", type=Path, default=None,
                   help="Original pcap, for printing minimal-repro command")
    args = p.parse_args(argv)

    res = diff(args.actual, args.expected, args.expected_slow, args.actual_slow)

    if res.matched:
        print(f"MATCH: {res.actual_count} events identical, slow-path counters agree.")
        return 0

    print("DIVERGE")
    print(res.diff_summary)
    if res.first_divergence_offset is not None and args.source_pcap is not None:
        print()
        print("Minimal repro:")
        print(
            f"  python3 -m sw.replay.itch_slice {args.source_pcap} "
            f"minimal.itch -n {res.first_divergence_offset + 1} --no-compress"
        )
    return 1


if __name__ == "__main__":
    sys.exit(main())
