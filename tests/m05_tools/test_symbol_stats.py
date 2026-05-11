"""Tests for sw.m05_tools.symbol_stats — exercises the per-symbol aggregator
on a tiny synthetic stream so we don't need real pcaps in CI."""
from __future__ import annotations

import struct
from pathlib import Path

from sw.refbook.synthetic_gen import (
    BOOK_EVENT_FMT,
    EV_ADD,
    EV_CANCEL,
    EV_DELETE,
    EV_EXEC,
    EV_EXECPX,
)
from sw.m05_tools.symbol_stats import compute_symbol_stats


def _write_events(path: Path, events: list[tuple[int, int, int, int, int, int, int]]) -> None:
    with path.open("wb") as f:
        for ev in events:
            f.write(struct.pack(BOOK_EVENT_FMT, *ev))


def test_aggregates_msg_count_and_type_mix(tmp_path: Path) -> None:
    p = tmp_path / "tiny.events.bin"
    # (ev_type, side, symbol_id, price, shares, order_id, ingress_ts)
    _write_events(p, [
        (EV_ADD,    0, 100, 1000, 100, 1, 0),
        (EV_ADD,    1, 100, 1010, 100, 2, 0),
        (EV_DELETE, 0, 100, 1000, 100, 1, 0),
        (EV_ADD,    0, 200, 2000, 100, 3, 0),
        (EV_EXEC,   0, 200, 2000,  10, 3, 0),
        (EV_EXECPX, 0, 200, 2000,  10, 3, 0),
        (EV_CANCEL, 0, 200, 2000,  10, 3, 0),
    ])
    stats = compute_symbol_stats(p)
    assert stats[100].msg_count == 3
    assert stats[100].type_counts["A"] == 2
    assert stats[100].type_counts["D"] == 1
    assert stats[100].price_min == 1000
    assert stats[100].price_max == 1010
    assert stats[200].msg_count == 4
    assert stats[200].type_counts["A"] == 1
    assert stats[200].type_counts["E"] == 1
    assert stats[200].type_counts["C"] == 1
    assert stats[200].type_counts["X"] == 1


def test_peak_open_orders(tmp_path: Path) -> None:
    p = tmp_path / "peak.events.bin"
    # 3 ADDs then 1 DELETE for a single symbol
    _write_events(p, [
        (EV_ADD,    0, 100, 1000, 100, 10, 0),
        (EV_ADD,    0, 100, 1000, 100, 11, 0),
        (EV_ADD,    0, 100, 1000, 100, 12, 0),
        (EV_DELETE, 0, 100, 1000, 100, 11, 0),
    ])
    stats = compute_symbol_stats(p)
    assert stats[100].peak_open_orders == 3, "peak should capture max simultaneously open"
