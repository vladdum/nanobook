"""Shared IO: reads the M04 32-byte BookEvent binary stream as an iterator
of typed records. No external dependencies beyond stdlib + the existing
sw.replay / sw.refbook packages.

NB. The plan referenced ``BOOK_EVENT_FORMAT`` from ``sw.replay.event_bin``
and ``BOOK_EVENT_SIZE`` from the same module. The canonical exports are
``BOOK_EVENT_FMT`` (lives in ``sw.refbook.synthetic_gen`` and is the
single source of truth — ``sw.replay.event_bin`` re-uses it) and
``RECORD_SIZE`` (in ``sw.replay.event_bin``). Used here unchanged.
"""
from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
import struct

from sw.refbook.synthetic_gen import (
    BOOK_EVENT_FMT,
    EV_ADD,
    EV_CANCEL,
    EV_DELETE,
    EV_EXEC,
    EV_EXECPX,
)
from sw.replay.event_bin import RECORD_SIZE


_EVENT_TYPE_NAMES = {
    EV_ADD:    "A",
    EV_CANCEL: "X",
    EV_DELETE: "D",
    EV_EXEC:   "E",
    EV_EXECPX: "C",
}


def event_type_name(t: int) -> str:
    return _EVENT_TYPE_NAMES.get(t, f"?{t}")


def iter_events(path: Path) -> Iterator[tuple[int, int, int, int, int, int, int]]:
    """Yields (ev_type, side, symbol_id, price, shares, order_id, ingress_ts)
    for each 32-byte BookEvent record in the file. Stops at EOF."""
    with path.open("rb") as f:
        while True:
            buf = f.read(RECORD_SIZE)
            if not buf:
                return
            if len(buf) != RECORD_SIZE:
                raise ValueError(f"truncated record at end of {path}")
            yield struct.unpack(BOOK_EVENT_FMT, buf)
