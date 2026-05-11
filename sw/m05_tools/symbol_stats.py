"""Per-symbol statistics aggregator over a 32-byte BookEvent binary stream.

Used by Phase B to pick the M05 single-symbol candidate. Output is a dict
keyed by symbol_id (== ITCH stock_locate) so the caller can sort and dump
top-N. Streams the file — does not load it into memory."""
from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from sw.m05_tools._io import event_type_name, iter_events
from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE


@dataclass
class SymbolStats:
    msg_count: int = 0
    type_counts: dict[str, int] = field(default_factory=dict)
    price_min: int | None = None
    price_max: int | None = None
    peak_open_orders: int = 0
    _open_orders: int = 0   # transient

    def _bump_type(self, t: int) -> None:
        n = event_type_name(t)
        self.type_counts[n] = self.type_counts.get(n, 0) + 1


def compute_symbol_stats(path: Path) -> Mapping[int, SymbolStats]:
    out: dict[int, SymbolStats] = {}
    for ev_type, _side, symbol_id, price, _shares, _order_id, _ts in iter_events(path):
        s = out.setdefault(symbol_id, SymbolStats())
        s.msg_count += 1
        s._bump_type(ev_type)
        if price > 0:   # skip zero-price marker rows
            s.price_min = price if s.price_min is None else min(s.price_min, price)
            s.price_max = price if s.price_max is None else max(s.price_max, price)
        if ev_type == EV_ADD:
            s._open_orders += 1
            if s._open_orders > s.peak_open_orders:
                s.peak_open_orders = s._open_orders
        elif ev_type == EV_DELETE:
            s._open_orders -= 1
    return out


def _format_report(stats: Mapping[int, SymbolStats], top_n: int = 50) -> str:
    rows = sorted(stats.items(), key=lambda kv: kv[1].msg_count, reverse=True)[:top_n]
    lines = ["| symbol | msg_count | A | D | E | X | U | C | price_min | price_max | peak_open |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for sid, s in rows:
        tc = s.type_counts
        lines.append(
            f"| {sid} | {s.msg_count} | "
            f"{tc.get('A', 0)} | {tc.get('D', 0)} | {tc.get('E', 0)} | "
            f"{tc.get('X', 0)} | {tc.get('U', 0)} | {tc.get('C', 0)} | "
            f"{s.price_min} | {s.price_max} | {s.peak_open_orders} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("events_bin", type=Path, help="32-byte BookEvent binary stream")
    ap.add_argument("--top", type=int, default=50)
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    stats = compute_symbol_stats(args.events_bin)
    report = _format_report(stats, top_n=args.top)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(report)
    else:
        print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
