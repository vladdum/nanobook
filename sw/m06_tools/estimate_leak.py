"""Residual pool-leak estimator. Models drop-on-rebase + inline-free.

For each event in the stream:
  - On ADD outside the current window: rebase. All previously open orders
    for that symbol become "stale". The pool slot is still allocated.
  - On DELETE/CANCEL/EXEC/EXEC_PX for a stale order: inline-free reclaims
    the slot (matches RTL §3.7). Counts toward "freed-via-inline-free".
  - At end of stream: any remaining stale orders not seen again are the
    residual leak.

Spec: §3.7, §5.2.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from sw.m05_tools._io import iter_events
from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE, EV_EXEC, EV_CANCEL


WINDOW_HALF = 2048


@dataclass
class LeakReport:
    rebase_count: int
    inline_freed: int
    residual_leak: int


def estimate_residual_leak(events: Path, *, picked_locates: set[int]) -> LeakReport:
    # Per-symbol state: epoch counter, current origin, open orders {order_id: epoch}
    epoch: dict[int, int] = {}
    origin: dict[int, int] = {}
    open_orders: dict[int, dict[int, int]] = {}  # symbol -> {order_id: ins_epoch}
    pool_leak_per_sym: dict[int, int] = {}
    rebase_count = 0
    inline_freed = 0

    for ev_type, _side, symbol_id, price, _shares, order_id, _ts in iter_events(events):
        if symbol_id not in picked_locates:
            continue
        epoch.setdefault(symbol_id, 0)
        origin.setdefault(symbol_id, price - WINDOW_HALF)  # seed
        open_orders.setdefault(symbol_id, {})
        pool_leak_per_sym.setdefault(symbol_id, 0)

        if ev_type == EV_ADD:
            # Rebase trigger
            o = origin[symbol_id]
            if price < o or price >= o + 2 * WINDOW_HALF:
                # All current open orders for this symbol become stale (old epoch).
                # Do NOT clear open_orders — keep them so DELETE/CANCEL/EXEC can
                # still arrive and trigger inline-free (§3.7). Increment epoch so
                # their ins_epoch != current epoch marks them stale.
                pool_leak_per_sym[symbol_id] += len(open_orders[symbol_id])
                epoch[symbol_id] += 1
                origin[symbol_id] = price - WINDOW_HALF
                rebase_count += 1
            open_orders[symbol_id][order_id] = epoch[symbol_id]
        elif ev_type in (EV_DELETE, EV_EXEC, EV_CANCEL):
            d = open_orders[symbol_id]
            if order_id in d:
                ins_epoch = d.pop(order_id)
                if ins_epoch != epoch[symbol_id]:
                    # stale — inline-free reclaims
                    inline_freed += 1
                    pool_leak_per_sym[symbol_id] = max(
                        0, pool_leak_per_sym[symbol_id] - 1
                    )
                # Non-stale: normal DELETE path, slot freed via splice; not a leak.

    residual = sum(pool_leak_per_sym.values())
    return LeakReport(
        rebase_count=rebase_count,
        inline_freed=inline_freed,
        residual_leak=residual,
    )


def _parse_locates_from_mem(mem: Path) -> set[int]:
    out: set[int] = set()
    for i, ln in enumerate(mem.read_text().splitlines()):
        v = int(ln.strip(), 16)
        if v & 0x80:
            out.add(i)
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--events", type=Path, required=True)
    ap.add_argument("--mem", type=Path,
                    default=Path("hw/ip/lob_core/lob_core_sym_init.mem"))
    args = ap.parse_args()
    locates = _parse_locates_from_mem(args.mem)
    rpt = estimate_residual_leak(args.events, picked_locates=locates)
    print(f"rebase_count={rpt.rebase_count} "
          f"inline_freed={rpt.inline_freed} "
          f"residual_leak={rpt.residual_leak}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
