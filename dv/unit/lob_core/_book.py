"""Cocotb helpers for lob_core unit TBs — drive book_event_t beats, collect
tob_delta_t beats, and a behavioural Python model that mirrors lob_core for
TB self-comparison.

The model is intentionally NOT the M02 refbook — the refbook is the
integration-TB authority. _book.py's model is a tiny single-symbol mirror used
for unit-level cycle-accurate TB reasoning."""
from __future__ import annotations

from dataclasses import dataclass, field
import struct

from cocotb.triggers import RisingEdge


# Mirror sw/refbook/synthetic_gen.BookEvent ("<BBHII4xQQ"):
# u8 ev_type, u8 side, u16 symbol_id, u32 price, u32 shares, 4B pad, u64 order_id, u64 ingress_ts.
_BOOK_EVENT_FORMAT = "<BBHII4xQQ"
BOOK_EVENT_BITS = 256


def pack_book_event(ev_type: int, side: int, symbol_id: int,
                    price: int, shares: int, order_id: int, ingress_ts: int) -> int:
    raw = struct.pack(_BOOK_EVENT_FORMAT, ev_type, side, symbol_id,
                      price, shares, order_id, ingress_ts)
    return int.from_bytes(raw, "little")


# Mirror sw/refbook/include/refbook/tob_delta.h (per spec §5.2, 32 B):
# u64 ingress_ts, u64 emit_ts, u16 symbol_id, u8 side, u8 reason,
# u32 new_best_price, u32 new_best_size, u32 flags.
_TOB_DELTA_FORMAT = "<QQHBBIII"
TOB_DELTA_BITS = 256


@dataclass
class TobDelta:
    ingress_ts: int
    emit_ts: int
    symbol_id: int
    side: int
    reason: int
    new_best_price: int
    new_best_size: int
    flags: int


def unpack_tob_delta(word: int) -> TobDelta:
    raw = int(word).to_bytes(TOB_DELTA_BITS // 8, "little")
    fields = struct.unpack(_TOB_DELTA_FORMAT, raw)
    return TobDelta(*fields)


async def reset(dut, *, cycles: int = 4) -> None:
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    dut.m_tready.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)


async def push_event(dut, ev_word: int, *, last: bool = True) -> None:
    """Drive one book_event_t beat. Waits for s_tready handshake."""
    dut.s_tdata.value = ev_word
    dut.s_tvalid.value = 1
    dut.s_tlast.value = 1 if last else 0
    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_tready.value):
            break
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0


async def collect_deltas(dut, *, n: int, max_cycles: int = 4096) -> list[TobDelta]:
    """Read up to n tob_delta_t beats, asserting m_tready."""
    out: list[TobDelta] = []
    dut.m_tready.value = 1
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value):
            out.append(unpack_tob_delta(int(dut.m_tdata.value)))
            if len(out) == n:
                dut.m_tready.value = 0
                return out
    dut.m_tready.value = 0
    raise TimeoutError(f"got {len(out)} of {n} deltas")


# Mini reference model — populated in Phase H tasks for the cycle-accurate TB.
@dataclass
class _MiniBook:
    bids: dict[int, list[tuple[int, int]]] = field(default_factory=dict)   # price -> [(order_id, shares)]
    asks: dict[int, list[tuple[int, int]]] = field(default_factory=dict)
    by_id: dict[int, tuple[int, int, int]] = field(default_factory=dict)   # order_id -> (side, price, shares)
