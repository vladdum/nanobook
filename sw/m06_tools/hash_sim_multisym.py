"""Multi-symbol hash worst-case probe across the picked symbols.

Extends sw/m05_tools/hash_sim.py — the M05 simulator (`simulate_open_addressing`)
operated on one symbol's order_id stream. M06's shared hash takes the **union**
of all picked symbols' order_id streams (since the hash key is order_id alone —
see spec §3.1 'order_id is globally unique/day').

The actual M05 API:
- `xorshift64(x)`, `crc32_low64(x)`, `fibonacci_mul(x)` — hash functions
- `simulate_open_addressing(seq, n_slots, hashfn) -> Probe` where seq is an
  iterable of (order_id, "ADD"|"DELETE")
- `Probe` dataclass with `worst_probe`, `p99_probe`, `peak_load_factor`,
  `inserts`, `deletes`
"""
from __future__ import annotations

import argparse
from pathlib import Path

from sw.m05_tools._io import iter_events
from sw.m05_tools.hash_sim import (
    Probe, simulate_open_addressing, xorshift64, crc32_low64, fibonacci_mul,
)
from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE


HASH_FNS = {
    "xorshift64":   xorshift64,
    "crc32_low64":  crc32_low64,
    "fibonacci_mul": fibonacci_mul,
}


def _replay_multisym(events: Path, picked_locates: set[int]):
    """Yield (order_id, op) for ADD/DELETE on any symbol in picked_locates."""
    for ev_type, _side, sid, _price, _shares, order_id, _ts in iter_events(events):
        if sid not in picked_locates:
            continue
        if ev_type == EV_ADD:
            yield (order_id, "ADD")
        elif ev_type == EV_DELETE:
            yield (order_id, "DELETE")


def simulate(events: Path, *, picked_locates: set[int], hash_slots: int,
             hash_fn=xorshift64) -> Probe:
    seq = list(_replay_multisym(events, picked_locates))
    return simulate_open_addressing(seq, hash_slots, hash_fn)


def _parse_locates_from_mem(mem: Path) -> set[int]:
    out: set[int] = set()
    for i, ln in enumerate(mem.read_text().splitlines()):
        v = int(ln.strip(), 16)
        if v & 0x80:
            out.add(i)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--events", type=Path, required=True)
    ap.add_argument("--mem", type=Path,
                    default=Path("hw/ip/lob_core/lob_core_sym_init.mem"))
    ap.add_argument("--hash-slots", type=int, default=32768)
    ap.add_argument("--hash-fn", choices=list(HASH_FNS), default="xorshift64")
    args = ap.parse_args()
    locates = _parse_locates_from_mem(args.mem)
    probe = simulate(args.events, picked_locates=locates,
                     hash_slots=args.hash_slots, hash_fn=HASH_FNS[args.hash_fn])
    print(f"worst_probe={probe.worst_probe} p99={probe.p99_probe} "
          f"peak_load={probe.peak_load_factor:.3f} "
          f"inserts={probe.inserts} deletes={probe.deletes}")
    if probe.worst_probe > 4:
        raise SystemExit(f"worst probe {probe.worst_probe} > 4 — pick a different hash_fn or larger hash_slots")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
