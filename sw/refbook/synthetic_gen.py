"""
Deterministic paired-stream generator for refbook tests and M03+ RTL TBs.

FROZEN at M02 (freeze-list: "Synthetic ITCH generator schema"). Consumers:
  - refbook GoogleTest reproducibility gate (M02).
  - M03 itch_decoder cocotb testbench.
  - M05+ book_core cocotb testbench.

Invariants:
  - generate_book_events(seed, ...) and generate_itch_bytes(seed, ...) with the
    same (seed, n_symbols, n_events) produce streams where decoding the ITCH
    stream yields the book_event stream byte-for-byte.
  - Output is byte-stable across Python 3.11/3.12 and any host arch.

Schema:
  - BookEvent is a 32-byte struct (see sw/refbook/include/refbook/book_event.h).
  - ITCH 5.0 messages: A, F, E, C, X, D, U — lengths per NASDAQ TVITCH 5.0 spec.
"""

from __future__ import annotations

import random
import struct
from dataclasses import dataclass
from typing import Iterator

# BookEvent struct layout mirrors include/refbook/book_event.h
# Layout: type(B) side(B) symbol_id(H) price(I) shares(I) _pad(4x) order_id(Q) ingress_ts(Q)
BOOK_EVENT_FMT = "<BBHII4xQQ"
BOOK_EVENT_SIZE = struct.calcsize(BOOK_EVENT_FMT)
assert BOOK_EVENT_SIZE == 32, BOOK_EVENT_SIZE

# EventType enum values.
EV_ADD, EV_CANCEL, EV_DELETE, EV_EXEC, EV_EXECPX = 0, 1, 2, 3, 4


@dataclass(frozen=True)
class BookEvent:
    type: int
    side: int
    symbol_id: int
    price: int
    shares: int
    order_id: int
    ingress_ts: int

    def pack(self) -> bytes:
        return struct.pack(
            BOOK_EVENT_FMT,
            self.type, self.side, self.symbol_id, self.price,
            self.shares, self.order_id, self.ingress_ts,
        )


def generate_book_events(
    seed: int,
    n_symbols: int = 100,
    n_events: int = 10_000_000,
    initial_midprice: int = 1_000_000,
) -> Iterator[BookEvent]:
    """Yield BookEvent records. Deterministic for a given seed.

    Uses parallel list + dict for O(1) random victim sampling (swap-pop on
    erase). The list holds order_ids in arbitrary order; the dict holds the
    per-id payload. RNG draw count per event is identical to a naive
    dict-only implementation, so the seeded stream remains stable for a
    given (seed, n_symbols, n_events).
    """
    rng = random.Random(seed)
    live_ids: list[int] = []
    live_data: dict[int, tuple[int, int, int, int]] = {}  # id -> (sym, side, price, shares)
    next_id = 1
    for i in range(n_events):
        ts = i + 1
        if not live_ids or rng.randrange(100) < 60:
            # ADD
            sym   = rng.randrange(n_symbols)
            side  = rng.randrange(2)
            price = initial_midprice + rng.randrange(-1000, 1001)
            shares = 1 + rng.randrange(1000)
            oid = next_id
            next_id += 1
            live_ids.append(oid)
            live_data[oid] = (sym, side, price, shares)
            yield BookEvent(EV_ADD, side, sym, price, shares, oid, ts)
        else:
            idx = rng.randrange(len(live_ids))
            victim_id = live_ids[idx]
            sym, side, price, shares = live_data[victim_id]
            roll = rng.randrange(100)
            if roll < 40:
                live_ids[idx] = live_ids[-1]
                live_ids.pop()
                del live_data[victim_id]
                yield BookEvent(EV_DELETE, 0, sym, 0, 0, victim_id, ts)
            elif roll < 70:
                delta = 1 + rng.randrange(shares)
                new_shares = shares - delta
                if new_shares <= 0:
                    live_ids[idx] = live_ids[-1]
                    live_ids.pop()
                    del live_data[victim_id]
                else:
                    live_data[victim_id] = (sym, side, price, new_shares)
                yield BookEvent(EV_CANCEL, 0, sym, 0, delta, victim_id, ts)
            else:
                delta = 1 + rng.randrange(shares)
                new_shares = shares - delta
                if new_shares <= 0:
                    live_ids[idx] = live_ids[-1]
                    live_ids.pop()
                    del live_data[victim_id]
                else:
                    live_data[victim_id] = (sym, side, price, new_shares)
                yield BookEvent(EV_EXEC, 0, sym, 0, delta, victim_id, ts)


def generate_itch_bytes(seed: int, n_symbols: int = 100, n_events: int = 10_000_000) -> bytes:
    """Return the ITCH 5.0 byte stream equivalent to generate_book_events()."""
    # Full ITCH encoding is out of scope for M02 itself but this function exists
    # as the freeze-list interface. The M03 decoder TB will exercise it; for M02
    # it is only required to be deterministic.
    out = bytearray()
    for ev in generate_book_events(seed, n_symbols, n_events):
        out.extend(_encode_itch(ev))
    return bytes(out)


def _decode_itch(msg: bytes) -> BookEvent:
    """Decode a single ITCH 5.0 fast-path message into a BookEvent.

    Inverse of _encode_itch() for fast-path types. Used by the round-trip
    test and by M03 cocotb TBs that need to compute the expected
    BookEvent from a raw ITCH byte sequence.
    """
    if not msg:
        raise ValueError("empty message")
    type_byte = msg[:1]
    if type_byte == b"A":
        # offsets per _itch_wire.FIELD_OFFSETS[b"A"]
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        side      = 0 if msg[19:20] == b"B" else 1
        shares    = int.from_bytes(msg[20:24], "big")
        price     = int.from_bytes(msg[32:36], "big")
        return BookEvent(EV_ADD, side, symbol_id, price, shares, order_id, ts48)
    if type_byte == b"D":
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        return BookEvent(EV_DELETE, 0, symbol_id, 0, 0, order_id, ts48)
    if type_byte == b"X":
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        cancelled = int.from_bytes(msg[19:23], "big")
        return BookEvent(EV_CANCEL, 0, symbol_id, 0, cancelled, order_id, ts48)
    if type_byte == b"E":
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        executed  = int.from_bytes(msg[19:23], "big")
        return BookEvent(EV_EXEC, 0, symbol_id, 0, executed, order_id, ts48)
    if type_byte == b"C":
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        executed  = int.from_bytes(msg[19:23], "big")
        price     = int.from_bytes(msg[32:36], "big")
        return BookEvent(EV_EXECPX, 0, symbol_id, price, executed, order_id, ts48)
    if type_byte == b"F":
        # F has same first 36 bytes as A plus 4-byte MPID; identical decode.
        symbol_id = int.from_bytes(msg[1:3],  "big")
        ts48      = int.from_bytes(msg[5:11], "big")
        order_id  = int.from_bytes(msg[11:19], "big")
        side      = 0 if msg[19:20] == b"B" else 1
        shares    = int.from_bytes(msg[20:24], "big")
        price     = int.from_bytes(msg[32:36], "big")
        return BookEvent(EV_ADD, side, symbol_id, price, shares, order_id, ts48)
    if type_byte == b"U":
        # Replace splits into DELETE + ADD; this Python decoder returns the
        # ADD half (downstream cocotb golden uses _split_replace() for both).
        symbol_id    = int.from_bytes(msg[1:3],   "big")
        ts48         = int.from_bytes(msg[5:11],  "big")
        new_order_id = int.from_bytes(msg[19:27], "big")
        shares       = int.from_bytes(msg[27:31], "big")
        price        = int.from_bytes(msg[31:35], "big")
        return BookEvent(EV_ADD, 0, symbol_id, price, shares, new_order_id, ts48)
    raise ValueError(f"unsupported ITCH type {type_byte!r}")


def _split_replace(msg: bytes) -> tuple[BookEvent, BookEvent]:
    """Decode an ITCH `U` (Replace) into the equivalent (DELETE, ADD) pair.

    The decoder RTL emits these two events back-to-back. This helper lets
    the cocotb golden compute the expected pair from a Replace message.
    """
    if msg[:1] != b"U":
        raise ValueError(f"_split_replace called on non-Replace message {msg[:1]!r}")
    symbol_id      = int.from_bytes(msg[1:3],   "big")
    ts48           = int.from_bytes(msg[5:11],  "big")
    orig_order_id  = int.from_bytes(msg[11:19], "big")
    new_order_id   = int.from_bytes(msg[19:27], "big")
    shares         = int.from_bytes(msg[27:31], "big")
    price          = int.from_bytes(msg[31:35], "big")
    delete_ev = BookEvent(EV_DELETE, 0, symbol_id, 0, 0, orig_order_id, ts48)
    add_ev    = BookEvent(EV_ADD,    0, symbol_id, price, shares, new_order_id, ts48)
    return delete_ev, add_ev


# Slow-path message lengths (subset; not exhaustive — only what M03 TBs
# need to exercise the decoder's drop-with-counter path).
_SLOW_PATH_LENGTHS: dict[bytes, int] = {
    b"R": 39,  # Stock Directory
    b"S": 12,  # System Event
    b"H": 25,  # Stock Trading Action
}


def _encode_itch_slow_path(type_byte: bytes) -> bytes:
    """Encode a slow-path ITCH message as [type][N-1 × 0xFF].

    The decoder's type-dispatch stage consumes the type byte, looks up
    the message length, advances past the body, and bumps the
    slow_path_dropped counter. The body content is irrelevant — dummy
    0xFF lets us confirm the decoder doesn't accidentally interpret it.
    """
    if type_byte not in _SLOW_PATH_LENGTHS:
        raise ValueError(f"unknown slow-path type {type_byte!r}")
    return type_byte + b"\xff" * (_SLOW_PATH_LENGTHS[type_byte] - 1)


def _encode_itch(ev: BookEvent) -> bytes:
    """Encode a BookEvent as a real ITCH 5.0 wire-format message.

    FROZEN at M03 (upgraded from the M02 placeholder). Per-type layouts
    follow NASDAQ TVITCH 5.0 v5.0. Multi-byte fields are big-endian.
    Stock symbol is 8 ASCII bytes right-padded with spaces; tracking
    number, timestamp, MPID are filled with deterministic-but-uninteresting
    values derived from ingress_ts so the encoder remains pure.

    Slow-path types: see _encode_itch_slow_path() — emits dummy payload of
    spec-correct length so the decoder's pre-filter is exercised without
    needing a full slow-path encoder.
    """
    ts48 = ev.ingress_ts & ((1 << 48) - 1)
    ts_bytes = ts48.to_bytes(6, "big")
    stock_locate = ev.symbol_id & 0xFFFF
    tracking = (ev.ingress_ts >> 16) & 0xFFFF
    stock_str = f"SYM{ev.symbol_id:05d}"[:8].ljust(8, " ").encode("ascii")

    if ev.type == EV_ADD:
        side_byte = b"B" if ev.side == 0 else b"S"
        return (
            b"A"
            + stock_locate.to_bytes(2, "big")
            + tracking.to_bytes(2, "big")
            + ts_bytes
            + ev.order_id.to_bytes(8, "big")
            + side_byte
            + ev.shares.to_bytes(4, "big")
            + stock_str
            + ev.price.to_bytes(4, "big")
        )
    if ev.type == EV_DELETE:
        return (
            b"D"
            + stock_locate.to_bytes(2, "big")
            + tracking.to_bytes(2, "big")
            + ts_bytes
            + ev.order_id.to_bytes(8, "big")
        )
    if ev.type == EV_CANCEL:
        return (
            b"X"
            + stock_locate.to_bytes(2, "big")
            + tracking.to_bytes(2, "big")
            + ts_bytes
            + ev.order_id.to_bytes(8, "big")
            + ev.shares.to_bytes(4, "big")
        )
    if ev.type == EV_EXEC:
        match_number = ev.order_id ^ ts48  # deterministic, uninteresting
        return (
            b"E"
            + stock_locate.to_bytes(2, "big")
            + tracking.to_bytes(2, "big")
            + ts_bytes
            + ev.order_id.to_bytes(8, "big")
            + ev.shares.to_bytes(4, "big")
            + match_number.to_bytes(8, "big")
        )
    if ev.type == EV_EXECPX:
        match_number = ev.order_id ^ ts48
        return (
            b"C"
            + stock_locate.to_bytes(2, "big")
            + tracking.to_bytes(2, "big")
            + ts_bytes
            + ev.order_id.to_bytes(8, "big")
            + ev.shares.to_bytes(4, "big")
            + match_number.to_bytes(8, "big")
            + b"Y"
            + ev.price.to_bytes(4, "big")
        )
    return b""
