"""Tests for sw/replay/event_bin.py.

The 32-byte serializer must mirror sw/refbook/include/refbook/book_event.h.
A read-then-write round-trip must be byte-identical.

Plan-vs-code adaptation: same as Phase B — no EventType enum class, no _pad
attribute. Real symbols come from sw.refbook.synthetic_gen (BookEvent dataclass
+ EV_ADD / EV_CANCEL flat constants).
"""
from __future__ import annotations

import io

import pytest

from sw.refbook.synthetic_gen import BOOK_EVENT_FMT, EV_ADD, EV_CANCEL, BookEvent
from sw.replay import event_bin


def _sample(t: int = EV_ADD, oid: int = 1) -> BookEvent:
    return BookEvent(
        type=t, side=1, symbol_id=42, price=12345,
        shares=100, order_id=oid, ingress_ts=0xDEADBEEF,
    )


def test_write_then_read_round_trip() -> None:
    ev = _sample()
    buf = io.BytesIO()
    event_bin.write(buf, ev)
    assert buf.tell() == 32
    buf.seek(0)
    out = event_bin.read(buf)
    assert out == ev


def test_byte_layout_matches_book_event_h() -> None:
    ev = BookEvent(
        type=EV_CANCEL, side=0, symbol_id=0xAABB,
        price=0x11223344, shares=0x55667788,
        order_id=0x1122334455667788, ingress_ts=0xCCDDEEFF00112233,
    )
    raw = event_bin.to_bytes(ev)
    assert len(raw) == 32
    # Spec §3.3 layout, little-endian (matches BOOK_EVENT_FMT '<BBHII4xQQ').
    assert raw[0:1] == bytes([1])              # Cancel = 1
    assert raw[1:2] == bytes([0])              # side
    assert raw[2:4] == (0xAABB).to_bytes(2, "little")
    assert raw[4:8] == (0x11223344).to_bytes(4, "little")
    assert raw[8:12] == (0x55667788).to_bytes(4, "little")
    assert raw[12:16] == (0).to_bytes(4, "little")  # _pad bytes
    assert raw[16:24] == (0x1122334455667788).to_bytes(8, "little")
    assert raw[24:32] == (0xCCDDEEFF00112233).to_bytes(8, "little")


def test_to_bytes_matches_synthetic_gen_pack() -> None:
    """event_bin.to_bytes must agree with BookEvent.pack() — they share
    the BOOK_EVENT_FMT layout. Catches future drift if either ever forks."""
    ev = _sample()
    assert event_bin.to_bytes(ev) == ev.pack()


def test_read_many_yields_in_order() -> None:
    evs = [_sample(oid=i) for i in range(5)]
    buf = io.BytesIO()
    for ev in evs:
        event_bin.write(buf, ev)
    buf.seek(0)
    out = list(event_bin.read_all(buf))
    assert out == evs


def test_truncated_read_raises() -> None:
    buf = io.BytesIO(b"\x00" * 31)  # short by 1 byte
    with pytest.raises(EOFError):
        event_bin.read(buf)


def test_read_all_rejects_misaligned_tail() -> None:
    """File length not a multiple of 32 must raise on the trailing partial."""
    ev = _sample()
    buf = io.BytesIO()
    event_bin.write(buf, ev)
    buf.write(b"\x00" * 7)  # 7 trailing bytes
    buf.seek(0)
    with pytest.raises(EOFError):
        list(event_bin.read_all(buf))


def test_record_size_matches_format() -> None:
    """Pin the on-disk record size to exactly the BOOK_EVENT_FMT struct size."""
    import struct as _struct
    assert event_bin.RECORD_SIZE == 32
    assert event_bin.RECORD_SIZE == _struct.calcsize(BOOK_EVENT_FMT)
