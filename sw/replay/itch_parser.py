"""Independent ITCH 5.0 parser, struct.unpack-based.

Designed to be authored *without reference* to sw/refbook/synthetic_gen._decode_itch
so that a shared decoding bug surfaces as a divergence in test_itch_parser.py.

Imports only the frozen wire constants from sw/refbook/_itch_wire.py and the
BookEvent dataclass + EV_* type constants from sw/refbook/synthetic_gen.py.

Public API:
- parse_one(msg: bytes) -> BookEvent | None: decode a single ITCH message.
  Returns None for slow-path types.
- parse(stream: bytes) -> Iterator[BookEvent | None]: yield one result per ITCH
  message in stream. Length-prefix framing is handled by the caller (e.g.,
  itch_slice or replay).

Side handling:
- ITCH 'B' = bid → side=0
- ITCH 'S' = ask → side=1
"""
from __future__ import annotations

import struct
from collections.abc import Iterator

from sw.refbook._itch_wire import MSG_LENGTHS
from sw.refbook.synthetic_gen import (
    EV_ADD,
    EV_CANCEL,
    EV_DELETE,
    EV_EXEC,
    EV_EXECPX,
    BookEvent,
)


_FAST_PATH_TYPES = frozenset(MSG_LENGTHS.keys())


def parse_one(msg: bytes) -> BookEvent | None:
    """Decode a single ITCH message. Returns None for slow-path types."""
    if not msg:
        raise ValueError("empty message")
    type_byte = msg[0:1]
    if type_byte not in _FAST_PATH_TYPES:
        return None
    expected_len = MSG_LENGTHS[type_byte]
    if len(msg) != expected_len:
        raise ValueError(
            f"message type {type_byte!r} expected {expected_len} bytes, got {len(msg)}"
        )

    if type_byte in (b"A", b"F"):
        return _parse_add(msg)
    if type_byte == b"E":
        return _parse_exec(msg)
    if type_byte == b"C":
        return _parse_exec_px(msg)
    if type_byte == b"X":
        return _parse_cancel(msg)
    if type_byte == b"D":
        return _parse_delete(msg)
    if type_byte == b"U":
        # Replace is handled by parse() because it produces 2 events.
        # parse_one returns the Add half (caller responsibility for the Delete);
        # use parse() for full streams.
        return _parse_replace_add_half(msg)
    raise AssertionError(f"unhandled fast-path type {type_byte!r}")


def parse(stream: bytes) -> Iterator[BookEvent | None]:
    """Stream-decode raw concatenated ITCH messages.

    Length-prefix framing is NOT consumed here; pass already-extracted message
    bodies (one at a time, concatenated) and this will split on type-byte length.
    For NASDAQ historical files (with 2-byte length prefix), use itch_slice or
    replay to strip the framing first.

    Replace ('U') yields two events: Delete then Add.
    """
    offset = 0
    while offset < len(stream):
        type_byte = stream[offset:offset + 1]
        if type_byte not in _FAST_PATH_TYPES:
            # Slow-path: caller framed exactly one message and gave us its bytes.
            # We cannot infer slow-path length without _itch_wire knowing it.
            # parse() is intended for fast-path-only streams; for mixed, use
            # length-prefix framing and call parse_one per message.
            raise ValueError(
                f"parse() requires fast-path-only input; got type {type_byte!r} "
                f"at offset {offset}. Use length-prefix framing + parse_one."
            )
        msg_len = MSG_LENGTHS[type_byte]
        msg = stream[offset:offset + msg_len]
        if type_byte == b"U":
            yield _parse_replace_delete_half(msg)
            yield _parse_replace_add_half(msg)
        else:
            yield parse_one(msg)
        offset += msg_len


# ─── Per-type parsers ────────────────────────────────────────────────────────────


def _side_from_byte(b: int) -> int:
    # ITCH: 'B' (0x42) = buy/bid → 0; 'S' (0x53) = sell/ask → 1.
    if b == 0x42:
        return 0
    if b == 0x53:
        return 1
    raise ValueError(f"invalid side byte 0x{b:02X}")


def _parse_add(msg: bytes) -> BookEvent:
    """ITCH 'A' (36 B) or 'F' (40 B)."""
    # offsets: order_id @11 (8 B), side @19 (1 B), shares @20 (4 B),
    # stock_locate @1 (2 B), price @32 (4 B)
    order_id = struct.unpack_from(">Q", msg, 11)[0]
    side = _side_from_byte(msg[19])
    shares = struct.unpack_from(">I", msg, 20)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    price = struct.unpack_from(">I", msg, 32)[0]
    return BookEvent(
        type=EV_ADD, side=side, symbol_id=symbol_id, price=price,
        shares=shares, order_id=order_id, ingress_ts=0,
    )


def _parse_exec(msg: bytes) -> BookEvent:
    """ITCH 'E' (31 B). Decrement-only; price/side preserved from original."""
    order_id = struct.unpack_from(">Q", msg, 11)[0]
    shares = struct.unpack_from(">I", msg, 19)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    return BookEvent(
        type=EV_EXEC, side=0, symbol_id=symbol_id, price=0,
        shares=shares, order_id=order_id, ingress_ts=0,
    )


def _parse_exec_px(msg: bytes) -> BookEvent:
    """ITCH 'C' (36 B). Exec at non-display price."""
    order_id = struct.unpack_from(">Q", msg, 11)[0]
    shares = struct.unpack_from(">I", msg, 19)[0]
    # price @32 (4 B); printable @31 (1 B) and match_id @23 (8 B) ignored
    price = struct.unpack_from(">I", msg, 32)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    return BookEvent(
        type=EV_EXECPX, side=0, symbol_id=symbol_id, price=price,
        shares=shares, order_id=order_id, ingress_ts=0,
    )


def _parse_cancel(msg: bytes) -> BookEvent:
    """ITCH 'X' (23 B). Partial cancel — shares delta only."""
    order_id = struct.unpack_from(">Q", msg, 11)[0]
    shares = struct.unpack_from(">I", msg, 19)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    return BookEvent(
        type=EV_CANCEL, side=0, symbol_id=symbol_id, price=0,
        shares=shares, order_id=order_id, ingress_ts=0,
    )


def _parse_delete(msg: bytes) -> BookEvent:
    """ITCH 'D' (19 B). Full remove."""
    order_id = struct.unpack_from(">Q", msg, 11)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    return BookEvent(
        type=EV_DELETE, side=0, symbol_id=symbol_id, price=0,
        shares=0, order_id=order_id, ingress_ts=0,
    )


def _parse_replace_delete_half(msg: bytes) -> BookEvent:
    """ITCH 'U' (35 B) → Delete on the original order_id."""
    old_order_id = struct.unpack_from(">Q", msg, 11)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    return BookEvent(
        type=EV_DELETE, side=0, symbol_id=symbol_id, price=0,
        shares=0, order_id=old_order_id, ingress_ts=0,
    )


def _parse_replace_add_half(msg: bytes) -> BookEvent:
    """ITCH 'U' (35 B) → Add on the new order_id with new shares + price."""
    new_order_id = struct.unpack_from(">Q", msg, 19)[0]
    new_shares = struct.unpack_from(">I", msg, 27)[0]
    new_price = struct.unpack_from(">I", msg, 31)[0]
    symbol_id = struct.unpack_from(">H", msg, 1)[0]
    # Replace doesn't transmit side; preserved by book core in M5+.
    # For decoder validation, side=0 here matches the M03 RTL convention.
    return BookEvent(
        type=EV_ADD, side=0, symbol_id=symbol_id, price=new_price,
        shares=new_shares, order_id=new_order_id, ingress_ts=0,
    )
