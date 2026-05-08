"""32-byte BookEvent serializer/deserializer (little-endian).

Layout mirrors sw/refbook/include/refbook/book_event.h byte-for-byte (M03 codegen
keeps the SystemVerilog package in sync; this module keeps the dump-file format
in sync with both).

Format (matches sw/refbook/synthetic_gen.BOOK_EVENT_FMT = '<BBHII4xQQ'):
  [0]     u8   type  (EV_ADD / EV_CANCEL / EV_DELETE / EV_EXEC / EV_EXECPX)
  [1]     u8   side
  [2:4]   u16  symbol_id
  [4:8]   u32  price
  [8:12]  u32  shares
  [12:16] u32  _pad (reserved, always zero)
  [16:24] u64  order_id
  [24:32] u64  ingress_ts (48 bits used; upper 16 = 0)

This module deliberately wraps `BookEvent.pack()` for the encode direction so
both paths share the single source of truth for byte layout.
"""
from __future__ import annotations

import struct
from collections.abc import Iterator
from typing import IO

from sw.refbook.synthetic_gen import BOOK_EVENT_FMT, BookEvent


_LAYOUT = struct.Struct(BOOK_EVENT_FMT)
RECORD_SIZE = _LAYOUT.size

assert RECORD_SIZE == 32, f"BookEvent layout must be exactly 32 bytes, got {RECORD_SIZE}"


def to_bytes(ev: BookEvent) -> bytes:
    """Serialize a BookEvent to 32 bytes."""
    return ev.pack()


def from_bytes(raw: bytes) -> BookEvent:
    """Deserialize 32 bytes into a BookEvent."""
    if len(raw) != RECORD_SIZE:
        raise ValueError(f"expected {RECORD_SIZE} bytes, got {len(raw)}")
    type_i, side, symbol_id, price, shares, order_id, ingress_ts = _LAYOUT.unpack(raw)
    return BookEvent(
        type=type_i,
        side=side,
        symbol_id=symbol_id,
        price=price,
        shares=shares,
        order_id=order_id,
        ingress_ts=ingress_ts,
    )


def write(fp: IO[bytes], ev: BookEvent) -> None:
    """Append one BookEvent to a binary stream."""
    fp.write(to_bytes(ev))


def read(fp: IO[bytes]) -> BookEvent:
    """Read one BookEvent from a binary stream. Raises EOFError if short."""
    raw = fp.read(RECORD_SIZE)
    if len(raw) < RECORD_SIZE:
        raise EOFError(f"truncated read: got {len(raw)}/{RECORD_SIZE}")
    return from_bytes(raw)


def read_all(fp: IO[bytes]) -> Iterator[BookEvent]:
    """Yield BookEvents until EOF. Raises if the file is not a multiple of 32."""
    while True:
        raw = fp.read(RECORD_SIZE)
        if not raw:
            return
        if len(raw) < RECORD_SIZE:
            raise EOFError(f"file not 32-byte aligned (trailing {len(raw)} bytes)")
        yield from_bytes(raw)
