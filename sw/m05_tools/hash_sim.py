"""Python model of the lob_core open-addressing hash table.

Used by Phase B to choose `(hash_function, slot_count)` such that worst-case
probe depth ≤ 4 across a full trading day for the chosen symbol. Models
linear-probing with tombstones — matches the planned RTL behavior in
`order_id_hash.sv`.
"""
from __future__ import annotations

from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path

from sw.m05_tools._io import iter_events
from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE


HashFn = Callable[[int], int]


_TOMBSTONE = -1
_EMPTY = 0


def xorshift64(x: int) -> int:
    x = (x ^ 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF   # seed empty input
    x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF
    x ^= (x >> 7)
    x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF
    return x & 0xFFFFFFFFFFFFFFFF


def crc32_low64(x: int) -> int:
    """zlib CRC32 over the low 64 bits, big-endian — matches a likely RTL choice."""
    import zlib
    return zlib.crc32((x & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big"))


_PHI64 = 0x9E3779B97F4A7C15


def fibonacci_mul(x: int) -> int:
    return ((x * _PHI64) & 0xFFFFFFFFFFFFFFFF)


@dataclass
class Probe:
    worst_probe: int = 0
    p99_probe: int = 0
    peak_load_factor: float = 0.0
    inserts: int = 0
    deletes: int = 0


def simulate_open_addressing(
    seq: Iterable[tuple[int, str]],
    n_slots: int,
    hashfn: HashFn,
) -> Probe:
    assert n_slots > 0 and (n_slots & (n_slots - 1)) == 0, "n_slots must be power of 2"
    mask = n_slots - 1
    table: list[int] = [_EMPTY] * n_slots   # 0 = empty, -1 = tombstone, otherwise order_id
    live = 0
    probe = Probe()
    probe_hist: list[int] = []
    for order_id, op in seq:
        h = hashfn(order_id) & mask
        if op == "ADD":
            depth = 1
            while table[h] != _EMPTY and table[h] != _TOMBSTONE and depth <= n_slots:
                h = (h + 1) & mask
                depth += 1
            if depth > n_slots:
                raise RuntimeError(f"hash table full at slot {h}")
            table[h] = order_id
            live += 1
            probe_hist.append(depth)
            probe.inserts += 1
        elif op == "DELETE":
            depth = 1
            while table[h] != order_id and depth <= n_slots:
                if table[h] == _EMPTY:
                    break   # not found — counts as 0-depth miss
                h = (h + 1) & mask
                depth += 1
            if depth <= n_slots and table[h] == order_id:
                table[h] = _TOMBSTONE
                live -= 1
                probe_hist.append(depth)
            probe.deletes += 1
        else:
            raise ValueError(f"unknown op: {op}")
        lf = live / n_slots
        if lf > probe.peak_load_factor:
            probe.peak_load_factor = lf
    if probe_hist:
        probe.worst_probe = max(probe_hist)
        probe_hist.sort()
        probe.p99_probe = probe_hist[int(len(probe_hist) * 0.99)]
    return probe


def replay_orderid_stream(events_bin: Path, symbol_id: int) -> list[tuple[int, str]]:
    """Yields (order_id, op) for ADD/DELETE only on the chosen symbol — feeds
    simulate_open_addressing. EXEC/EXEC_PX/CANCEL do not affect hash occupancy
    until shares==0; conservatively model them as no-op for sizing."""
    seq: list[tuple[int, str]] = []
    for ev_type, _side, sid, _price, _shares, order_id, _ts in iter_events(events_bin):
        if sid != symbol_id:
            continue
        if ev_type == EV_ADD:
            seq.append((order_id, "ADD"))
        elif ev_type == EV_DELETE:
            seq.append((order_id, "DELETE"))
    return seq


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("events_bin", type=Path)
    ap.add_argument("--symbol", type=int, required=True, help="stock_locate of chosen symbol")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    seq = replay_orderid_stream(args.events_bin, args.symbol)
    funcs: list[tuple[str, HashFn]] = [
        ("xorshift64", xorshift64),
        ("crc32_low64", crc32_low64),
        ("fibonacci_mul", fibonacci_mul),
    ]
    slot_counts = [65536, 131072, 262144, 524288]
    lines = ["| hash | " + " | ".join(f"N={n // 1024}K" for n in slot_counts) + " |",
             "| --- | " + " | ".join("---" for _ in slot_counts) + " |"]
    for name, fn in funcs:
        cells = [name]
        for n in slot_counts:
            p = simulate_open_addressing(seq, n, fn)
            cells.append(f"({p.worst_probe}, {p.p99_probe}, {p.peak_load_factor:.3f})")
        lines.append("| " + " | ".join(cells) + " |")
    body = "\n".join(lines) + "\n"
    out = (
        f"# M05 hash sizing — symbol_id={args.symbol}\n\n"
        f"Source: `{args.events_bin}` ({len(seq)} ADD/DELETE ops on the chosen symbol).\n\n"
        f"Each cell: `(worst_probe, p99_probe, peak_load_factor)`.\n\n"
        f"{body}"
    )
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(out)
    else:
        print(out, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
