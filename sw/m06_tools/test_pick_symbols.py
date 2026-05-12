"""TDD for pick_symbols — exercises the filter ladder on synthetic stats."""
from __future__ import annotations

import pytest

from sw.m06_tools.pick_symbols import (
    Candidate, select_symbols, format_sv_pkg, format_init_mem,
)


def _cand(loc: int, msgs: int, peak: int, span: int, has_a: bool, has_d: bool,
          mid: int = 100_000) -> Candidate:
    return Candidate(
        stock_locate=loc, msg_count=msgs, peak_open_orders=peak,
        price_span_ticks=span, has_a=has_a, has_d=has_d,
        first_add_price=mid,
    )


def test_filter_peak_50_picks_top_100_by_msg_count():
    # 120 candidates; 20 with peak > 50 are dropped, top 100 by msg count remain.
    cands = []
    for i in range(120):
        cands.append(_cand(
            loc=1000 + i, msgs=1_000_000 - i * 1000,
            peak=80 if i < 20 else 30,
            span=10_000, has_a=True, has_d=True,
        ))
    picked, fallback = select_symbols(cands, n_symbols=100, peak_max=50,
                                       span_max=4096 * 8)
    assert fallback == "primary"
    assert len(picked) == 100
    # Top msg-count survivors (skipping the 20 high-peak heads)
    assert picked[0].stock_locate == 1020
    assert picked[-1].stock_locate == 1119


def test_filter_falls_back_to_peak_80_when_primary_short():
    cands = [_cand(loc=1000 + i, msgs=1_000_000 - i, peak=70, span=10_000,
                    has_a=True, has_d=True) for i in range(100)]
    picked, fallback = select_symbols(cands, n_symbols=100, peak_max=50,
                                       span_max=4096 * 8)
    assert fallback == "peak_80"
    assert len(picked) == 100


def test_filter_falls_back_to_peak_120_when_peak_80_short():
    cands = [_cand(loc=1000 + i, msgs=1_000_000 - i, peak=110, span=10_000,
                    has_a=True, has_d=True) for i in range(100)]
    picked, fallback = select_symbols(cands, n_symbols=100, peak_max=50,
                                       span_max=4096 * 8)
    assert fallback == "peak_120"


def test_filter_rejects_when_all_fallbacks_short():
    cands = [_cand(loc=1000 + i, msgs=1_000_000 - i, peak=200, span=10_000,
                    has_a=True, has_d=True) for i in range(100)]
    with pytest.raises(ValueError, match="exhausted"):
        select_symbols(cands, n_symbols=100, peak_max=50, span_max=4096 * 8)


def test_filter_rejects_symbols_missing_a_or_d():
    # 100 valid + 1 invalid (no-DELETE) = 101 candidates; filter excludes the
    # invalid one and we still have 100 survivors. msg_count of the bad
    # candidate is high (2M) so it would have sorted to the top if accepted.
    cands = [_cand(loc=1000 + i, msgs=1_000_000 - i, peak=30, span=10_000,
                    has_a=True, has_d=True) for i in range(100)]
    cands.append(_cand(loc=9999, msgs=2_000_000, peak=30, span=10_000,
                        has_a=True, has_d=False))  # No DELETE — excluded
    picked, fallback = select_symbols(cands, n_symbols=100, peak_max=50,
                                       span_max=4096 * 8)
    assert fallback == "primary"
    assert 9999 not in {c.stock_locate for c in picked}
    assert len(picked) == 100


def test_format_sv_pkg_emits_8192_entry_lut():
    cands = [_cand(loc=1000 + i, msgs=1, peak=1, span=1,
                    has_a=True, has_d=True, mid=100_000 + i)
             for i in range(3)]
    sv = format_sv_pkg(cands)
    # 8192 slots, 7-bit sym_idx + 1 valid bit packed into 8 bits per slot
    assert "STOCK_LOCATE_TO_SYM_IDX [8192]" in sv
    assert "INITIAL_MIDPRICE [3]" in sv
    # Slot 1000 → valid + sym_idx=0 → 0x80
    assert "8'h80" in sv  # at index 1000


def test_format_init_mem_one_byte_per_line_8192_lines():
    cands = [_cand(loc=1000, msgs=1, peak=1, span=1,
                    has_a=True, has_d=True)]
    mem = format_init_mem(cands)
    lines = mem.strip().split("\n")
    assert len(lines) == 8192
    assert lines[0] == "00"    # locate=0 unmapped
    assert lines[1000] == "80"  # locate=1000 mapped to sym_idx=0, valid
