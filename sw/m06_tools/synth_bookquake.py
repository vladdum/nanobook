"""Synthesise a book-quake event stream.

Phase 1: seed `per-sym-orders` in-window ADDs for each of N picked
symbols. Phase 2: emit one rebase-trigger ADD per symbol whose price
jumps outside the static lob_core window (so the OOW path fires and
bumps rebases_total). All events are clustered within a 1 µs window
(256 cycles @ 250 MHz).

Output: 32 B BookEvent binary stream consumable by
`sw.m05_tools._io.iter_events` (and by the book-quake TB).

Note (intentional deviation from plan §I.1):
    The plan's example uses `symbol_id=1000 + sym_idx`. Those values
    are not in the picked-100 LUT, so lob_core's sym_idx_lut would drop
    every event before it reaches the rebase trigger. To exercise the
    rebase path this generator instead emits using the first N picked
    stock_locates from `hw/ip/lob_core/lob_core_sym_init.mem`. Also,
    `BookEvent` fields are `type` / `side` / ... — not `ev_type` — so
    the constructor calls below use the real field names.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from sw.refbook.synthetic_gen import EV_ADD, BookEvent


REPO = Path(__file__).resolve().parents[2]
SYM_INIT_MEM = REPO / "hw" / "ip" / "lob_core" / "lob_core_sym_init.mem"

# Match lob_core_params_pkg: WINDOW_BASE_TICK=354000, WINDOW_SIZE_TICKS=4096.
# In-window prices live in [354000, 358096); the rebase ADDs jump well
# above the upper bound to guarantee the OOW path fires.
WINDOW_BASE_TICK  = 354_000
WINDOW_SIZE_TICKS = 4_096
IN_WINDOW_BASE    = WINDOW_BASE_TICK + 100   # 354100, comfortably inside
OOW_BASE          = WINDOW_BASE_TICK + 100_000  # 454000, far above the window


def _picked_locates() -> list[int]:
    """Return picked stock_locates from sym_init.mem, sorted by sym_idx so
    callers can pick the first N consistently across runs."""
    pairs: list[tuple[int, int]] = []  # (sym_idx, stock_locate)
    for stock_locate, line in enumerate(SYM_INIT_MEM.read_text().splitlines()):
        line = line.strip()
        if not line:
            continue
        v = int(line, 16)
        if v & 0x80:
            sym_idx = v & 0x7F
            pairs.append((sym_idx, stock_locate))
    pairs.sort()
    return [sl for (_si, sl) in pairs]


def synth_bookquake(n_syms: int, per_sym_orders: int) -> list[BookEvent]:
    picked = _picked_locates()
    if n_syms > len(picked):
        raise ValueError(
            f"requested n_syms={n_syms} but only {len(picked)} picked locates"
        )
    syms = picked[:n_syms]

    events: list[BookEvent] = []
    ts = 0

    # Phase 1: in-window seed ADDs, one cycle apart.
    for sym_idx, stock_locate in enumerate(syms):
        for i in range(per_sym_orders):
            events.append(BookEvent(
                type=EV_ADD,
                side=i & 1,
                symbol_id=stock_locate,
                price=IN_WINDOW_BASE + i * 4,
                shares=100,
                order_id=(sym_idx << 16) | i,
                ingress_ts=ts,
            ))
            ts += 1

    # Phase 2: per-sym OOW ADD (rebase trigger). Cluster them within a
    # 256-cycle window so the TB can verify per-rebase stall is bounded.
    cluster_start = ts
    for sym_idx, stock_locate in enumerate(syms):
        events.append(BookEvent(
            type=EV_ADD,
            side=0,
            symbol_id=stock_locate,
            price=OOW_BASE + sym_idx * 100,
            shares=200,
            order_id=(sym_idx << 16) | 0xFFFF,
            ingress_ts=ts,
        ))
        ts += 1
    cluster_span = ts - cluster_start
    if cluster_span > 256:
        # Soft guard: at default n_syms=10 this is 10 events spanning
        # 10 cycles, well under 256.
        raise ValueError(f"rebase cluster span {cluster_span} > 256 cycles")

    return events


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--n-syms", type=int, default=10)
    ap.add_argument("--per-sym-orders", type=int, default=5)
    args = ap.parse_args()

    events = synth_bookquake(args.n_syms, args.per_sym_orders)
    with args.out.open("wb") as f:
        for ev in events:
            f.write(ev.pack())

    print(f"wrote {len(events)} events to {args.out} "
          f"({args.n_syms} syms, {args.per_sym_orders} orders/sym, "
          f"+{args.n_syms} rebase triggers)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
