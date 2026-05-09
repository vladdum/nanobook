"""Tests for sw/replay/event_diff.py.

The diff tool must:
1. Return MATCH if both streams are identical.
2. Report the first divergent message offset, with field-level breakdown.
3. Detect length mismatches.
4. Report slow-path counter mismatches.

Plan-vs-code adaptation (same as Phase B/D/F): real BookEvent + EV_*
constants from sw.refbook.synthetic_gen, no _pad attribute.
"""
from __future__ import annotations

from pathlib import Path

from sw.refbook.synthetic_gen import EV_ADD, BookEvent
from sw.replay import event_bin, event_diff


def _ev(oid: int, t: int = EV_ADD) -> BookEvent:
    return BookEvent(
        type=t, side=0, symbol_id=42, price=100,
        shares=10, order_id=oid, ingress_ts=0,
    )


def _write(path: Path, evs: list[BookEvent]) -> None:
    with path.open("wb") as fp:
        for ev in evs:
            event_bin.write(fp, ev)


def test_match_returns_zero(tmp_path: Path) -> None:
    a = tmp_path / "a.bin"
    b = tmp_path / "b.bin"
    evs = [_ev(i) for i in range(5)]
    _write(a, evs)
    _write(b, evs)

    result = event_diff.diff(a, b)
    assert result.matched
    assert result.first_divergence_offset is None


def test_divergence_reported_at_offset(tmp_path: Path) -> None:
    a = tmp_path / "a.bin"
    b = tmp_path / "b.bin"
    a_evs = [_ev(i) for i in range(5)]
    b_evs = [_ev(i) for i in range(5)]
    b_evs[2] = _ev(99)  # diverges at index 2

    _write(a, a_evs)
    _write(b, b_evs)

    result = event_diff.diff(a, b)
    assert not result.matched
    assert result.first_divergence_offset == 2
    assert "order_id" in result.diff_summary


def test_length_mismatch_detected(tmp_path: Path) -> None:
    a = tmp_path / "a.bin"
    b = tmp_path / "b.bin"
    _write(a, [_ev(i) for i in range(3)])
    _write(b, [_ev(i) for i in range(5)])

    result = event_diff.diff(a, b)
    assert not result.matched
    assert "length mismatch" in result.diff_summary.lower()


def test_slow_path_counter_mismatch(tmp_path: Path) -> None:
    a = tmp_path / "a.bin"
    b = tmp_path / "b.bin"
    _write(a, [_ev(0)])
    _write(b, [_ev(0)])

    result = event_diff.diff(a, b, expected_slow=10, actual_slow=11)
    assert not result.matched
    assert "slow_path_dropped" in result.diff_summary
