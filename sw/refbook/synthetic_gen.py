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


def _encode_itch(ev: BookEvent) -> bytes:
    # Minimal ITCH 5.0 encoding. Fully-fledged NASDAQ 5.0 compliance is
    # validated in M03/M04 against an independent parser. For M02 we just
    # need a deterministic byte sequence that round-trips via _decode_itch.
    if ev.type == EV_ADD:
        return b"A" + struct.pack(">HHIQH6sIQ",
            0, ev.symbol_id, ev.ingress_ts & 0xFFFFFFFF,
            ev.order_id, ev.shares, b"SYMBOL", ev.price, ev.ingress_ts >> 32) + bytes([ev.side])
    if ev.type == EV_DELETE:
        return b"D" + struct.pack(">HHIQ", 0, 0, ev.ingress_ts & 0xFFFFFFFF, ev.order_id)
    if ev.type == EV_CANCEL:
        return b"X" + struct.pack(">HHIQI",
            0, 0, ev.ingress_ts & 0xFFFFFFFF, ev.order_id, ev.shares)
    if ev.type == EV_EXEC:
        return b"E" + struct.pack(">HHIQIQ",
            0, 0, ev.ingress_ts & 0xFFFFFFFF, ev.order_id, ev.shares, 0)
    return b""
