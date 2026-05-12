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


async def reset(dut, *, cycles: int = 4,
                pss_sym0_origin: int = 10000,
                pss_sym0_midprice: int = 12048) -> None:
    """Reset the DUT and (post-F.2 §2) realign per_sym_state[sym=0] to the
    smoke / cycles TB's overridden WINDOW_BASE_TICK.

    The package-default INITIAL_MIDPRICE[0] is AAPL's real 2019-03-27
    midprice (354200), so post-F.2 the ladder address math uses an origin
    far from the TBs' price=10000-range events. After releasing rstn we
    backdoor-write sym=0's origin / midprice to align with the test's
    WINDOW_BASE_TICK override. Multi-symbol TBs that exercise the real
    per-sym values should pass explicit pss_sym0_* arguments or skip the
    backdoor by reading the actual package value."""
    dut.rstn.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    dut.m_tready.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    await RisingEdge(dut.clk)
    # Backdoor-realign sym=0's per-sym state to the TB's window. Other
    # syms keep their package-default origin (which is fine — no test
    # event addresses those slots).
    if hasattr(dut, 'u_pss'):
        try:
            dut.u_pss.origin_reg[0].value   = pss_sym0_origin
            dut.u_pss.midprice_reg[0].value = pss_sym0_midprice
        except (AttributeError, IndexError):
            pass


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


# ===========================================================================
# M06 pool record layout (256 bits) — M05-compatible (minimal diff from M05)
# ---------------------------------------------------------------------------
# Repurposes M05's _pad[7:0] field → {sym_idx[6:0], side[0]}, and the upper
# 16 bits of ingress_ts (which was 64b but ITCH ts is 48b) → ins_epoch.
# All other M05 bit positions unchanged. Phase B uses this layout; Phase F
# adds the per_sym_state regfile that owns the epoch values.
#
#   [255:232] next      (24b)   — M05 DLL next pointer
#   [231:208] prev      (24b)   — M05 DLL prev pointer
#   [207:176] shares    (32b)   — M05 unchanged
#   [175:144] price     (32b)   — M05 unchanged
#   [143:137] sym_idx   (7b)    — M06 (was _pad in M05)
#   [136]     side      (1b)    — M05 unchanged
#   [135:128] _pad      (8b)    — M05 unchanged
#   [127:64]  order_id  (64b)   — M05 unchanged
#   [63:48]   ins_epoch (16b)   — M06 (was upper-16 of ingress_ts in M05)
#   [47:0]    ingress_ts (48b)  — M06 truncated to ITCH-spec width
# ===========================================================================
M06_RECORD_W = 256


def pack_pool_record_m06(*, order_id: int, side: int, price: int, shares: int,
                          prev: int, next: int, sym_idx: int,
                          ins_epoch: int, ingress_ts: int = 0) -> int:
    return (
        (next & 0xFFFFFF) << 232
        | (prev & 0xFFFFFF) << 208
        | (shares & 0xFFFFFFFF) << 176
        | (price & 0xFFFFFFFF) << 144
        | (sym_idx & 0x7F) << 137
        | (side & 0x1) << 136
        | (order_id & 0xFFFFFFFFFFFFFFFF) << 64
        | (ins_epoch & 0xFFFF) << 48
        | (ingress_ts & 0xFFFFFFFFFFFF)
    )


def unpack_pool_record_m06(rec: int) -> dict:
    return {
        "next":       (rec >> 232) & 0xFFFFFF,
        "prev":       (rec >> 208) & 0xFFFFFF,
        "shares":     (rec >> 176) & 0xFFFFFFFF,
        "price":      (rec >> 144) & 0xFFFFFFFF,
        "sym_idx":    (rec >> 137) & 0x7F,
        "side":       (rec >> 136) & 0x1,
        "order_id":   (rec >> 64)  & 0xFFFFFFFFFFFFFFFF,
        "ins_epoch":  (rec >> 48)  & 0xFFFF,
        "ingress_ts": rec & 0xFFFFFFFFFFFF,
    }
