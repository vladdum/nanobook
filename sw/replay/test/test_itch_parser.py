"""Tests that the new struct.unpack-based ITCH parser:
1. Round-trips synthetic_gen output to the same BookEvent values.
2. Returns None on slow-path message types.

Author intentionally has NOT read synthetic_gen._decode_itch — the parsers are
independent so that a shared bug surfaces as a synthetic-round-trip mismatch.

Plan-text adaptation (recorded in local M04 plan amendment):
- The plan referenced `EventType.Add` etc., a `_pad=0` BookEvent field, and a
  `from sw.refbook.include.refbook.book_event import BookEvent, EventType`
  module. None of those exist; M02 froze BookEvent as a dataclass in
  synthetic_gen.py with flat EV_* constants and 4 padding bytes baked into the
  struct format. Test is rewritten to use the real symbols.
- The plan called `synthetic_gen._encode_replace(...)`; only `_split_replace`
  exists. The Replace test constructs the 35-byte ITCH 'U' message manually.
- The plan parametrized slow-path types over [S, R, H, Y, L, P, Q]; the
  `_encode_itch_slow_path` helper only knows S, R, H. Reduced to those.
"""
from __future__ import annotations

import struct

import pytest

from sw.refbook import synthetic_gen
from sw.refbook.synthetic_gen import (
    EV_ADD,
    EV_CANCEL,
    EV_DELETE,
    EV_EXEC,
    EV_EXECPX,
    BookEvent,
)
from sw.replay import itch_parser


def test_add_round_trip() -> None:
    ev = BookEvent(
        type=EV_ADD, side=0, symbol_id=42, price=12345,
        shares=100, order_id=0xCAFEF00D, ingress_ts=0,
    )
    raw = synthetic_gen._encode_itch(ev)
    out = itch_parser.parse_one(raw)
    assert out == ev


def test_exec_round_trip() -> None:
    ev = BookEvent(
        type=EV_EXEC, side=0, symbol_id=42, price=0,
        shares=50, order_id=0xCAFEF00D, ingress_ts=0,
    )
    raw = synthetic_gen._encode_itch(ev)
    out = itch_parser.parse_one(raw)
    assert out == ev


def test_exec_px_round_trip() -> None:
    ev = BookEvent(
        type=EV_EXECPX, side=0, symbol_id=42, price=98765,
        shares=50, order_id=0xCAFEF00D, ingress_ts=0,
    )
    raw = synthetic_gen._encode_itch(ev)
    out = itch_parser.parse_one(raw)
    assert out == ev


def test_cancel_round_trip() -> None:
    ev = BookEvent(
        type=EV_CANCEL, side=0, symbol_id=42, price=0,
        shares=25, order_id=0xCAFEF00D, ingress_ts=0,
    )
    raw = synthetic_gen._encode_itch(ev)
    out = itch_parser.parse_one(raw)
    assert out == ev


def test_delete_round_trip() -> None:
    ev = BookEvent(
        type=EV_DELETE, side=0, symbol_id=42, price=0,
        shares=0, order_id=0xCAFEF00D, ingress_ts=0,
    )
    raw = synthetic_gen._encode_itch(ev)
    out = itch_parser.parse_one(raw)
    assert out == ev


def _encode_replace_msg(
    *,
    old_order_id: int,
    new_order_id: int,
    new_shares: int,
    new_price: int,
    symbol_id: int,
) -> bytes:
    """Build a 35-byte ITCH 'U' (Order Replace) message.

    Wire layout per sw/refbook/_itch_wire.FIELD_OFFSETS[b"U"]:
      type(1) | stock_locate(2) | tracking_number(2) | timestamp(6)
      | orig_order_id(8) | new_order_id(8) | shares(4) | price(4)
    """
    return (
        b"U"
        + struct.pack(">H", symbol_id)
        + b"\x00\x00"                    # tracking_number (don't-care)
        + b"\x00" * 6                     # timestamp (don't-care)
        + struct.pack(">Q", old_order_id)
        + struct.pack(">Q", new_order_id)
        + struct.pack(">I", new_shares)
        + struct.pack(">I", new_price)
    )


def test_replace_splits_to_delete_plus_add() -> None:
    """ITCH 'U' (Replace) must split into one Delete + one Add."""
    raw = _encode_replace_msg(
        old_order_id=0xAAAA,
        new_order_id=0xBBBB,
        new_shares=200,
        new_price=99999,
        symbol_id=42,
    )
    events = list(itch_parser.parse(raw))
    assert len(events) == 2
    assert events[0] is not None and events[0].type == EV_DELETE
    assert events[0].order_id == 0xAAAA
    assert events[1] is not None and events[1].type == EV_ADD
    assert events[1].order_id == 0xBBBB
    assert events[1].shares == 200
    assert events[1].price == 99999


@pytest.mark.parametrize("type_byte", [b"S", b"R", b"H"])
def test_slow_path_returns_none(type_byte: bytes) -> None:
    raw = synthetic_gen._encode_itch_slow_path(type_byte)
    assert itch_parser.parse_one(raw) is None


def test_stream_yields_one_per_message() -> None:
    """parse() yields one BookEvent per fast-path message; slow-path bytes
    are not allowed in parse() input — they raise ValueError."""
    msgs: list[bytes] = []
    for symbol_id in range(10):
        ev = BookEvent(
            type=EV_ADD, side=0, symbol_id=symbol_id, price=100,
            shares=10, order_id=symbol_id, ingress_ts=0,
        )
        msgs.append(synthetic_gen._encode_itch(ev))

    stream = b"".join(msgs)
    out = list(itch_parser.parse(stream))
    assert len(out) == 10
    for got, want_symbol_id in zip(out, range(10)):
        assert got is not None
        assert got.type == EV_ADD
        assert got.symbol_id == want_symbol_id
