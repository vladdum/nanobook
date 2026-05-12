"""TDD for residual leak estimator. Inline-free reclaims orders that see
subsequent DELETE/X/E/C events; the remainder leak until pool wrap."""
from __future__ import annotations

from pathlib import Path

from sw.m06_tools.estimate_leak import estimate_residual_leak


def test_no_rebase_no_leak(tmp_path: Path):
    # Synthetic event stream: 100 ADDs followed by 100 DELETEs for the same
    # symbol. No price spike → no rebase → no leak.
    from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE, BookEvent

    events_path = tmp_path / "events.bin"
    with events_path.open("wb") as f:
        for i in range(100):
            f.write(BookEvent(
                type=EV_ADD, side=0, symbol_id=1000,
                price=100_000, shares=100, order_id=i + 1, ingress_ts=i,
            ).pack())
        for i in range(100):
            f.write(BookEvent(
                type=EV_DELETE, side=0, symbol_id=1000,
                price=100_000, shares=0, order_id=i + 1, ingress_ts=200 + i,
            ).pack())

    rpt = estimate_residual_leak(events_path, picked_locates={1000})
    assert rpt.rebase_count == 0
    assert rpt.residual_leak == 0


def test_rebase_with_subsequent_deletes_freed(tmp_path: Path):
    """An ADD at price 1M, then ADD at 100M triggers rebase. The first
    order's DELETE is then a stale_check hit → inline-free → 0 leak."""
    from sw.refbook.synthetic_gen import EV_ADD, EV_DELETE, BookEvent

    events_path = tmp_path / "events.bin"
    with events_path.open("wb") as f:
        f.write(BookEvent(
            type=EV_ADD, side=0, symbol_id=1000,
            price=1_000_000, shares=100, order_id=1, ingress_ts=0,
        ).pack())
        f.write(BookEvent(
            type=EV_ADD, side=0, symbol_id=1000,
            price=100_000_000, shares=100, order_id=2, ingress_ts=1,
        ).pack())  # Triggers rebase
        f.write(BookEvent(
            type=EV_DELETE, side=0, symbol_id=1000,
            price=0, shares=0, order_id=1, ingress_ts=2,
        ).pack())  # Stale — but DELETE arrives → inline-free
    rpt = estimate_residual_leak(events_path, picked_locates={1000})
    assert rpt.rebase_count == 1
    assert rpt.residual_leak == 0


def test_rebase_without_subsequent_delete_leaks(tmp_path: Path):
    """An ADD followed by rebase but no DELETE for the rebased order → 1 leak."""
    from sw.refbook.synthetic_gen import EV_ADD, BookEvent

    events_path = tmp_path / "events.bin"
    with events_path.open("wb") as f:
        f.write(BookEvent(
            type=EV_ADD, side=0, symbol_id=1000,
            price=1_000_000, shares=100, order_id=1, ingress_ts=0,
        ).pack())
        f.write(BookEvent(
            type=EV_ADD, side=0, symbol_id=1000,
            price=100_000_000, shares=100, order_id=2, ingress_ts=1,
        ).pack())
    rpt = estimate_residual_leak(events_path, picked_locates={1000})
    assert rpt.rebase_count == 1
    assert rpt.residual_leak == 1
