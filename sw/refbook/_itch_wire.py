"""ITCH 5.0 wire format — message lengths and per-type field offsets.

Spec reference: NASDAQ TotalView-ITCH 5.0 Specification (v5.0, 2014-09-19),
sections 4.3 (Add Order), 4.4 (Order Executed), 4.5 (Order Cancel),
4.6 (Order Delete), 4.7 (Order Replace).

Multi-byte fields are big-endian on the wire. ITCH offsets in this module
are byte offsets from the start of the message INCLUDING the 1-byte type
prefix, matching how the decoder will read them off the AXI-S input.

This module is FROZEN at M03 alongside the synthetic_gen ITCH encoder
upgrade; consumers include the encoder, decoder, cocotb TBs, and any
M04+ tooling that needs to construct or interpret ITCH bytes.
"""
from __future__ import annotations

from typing import Final

# Total message length in bytes, including the 1-byte type prefix.
MSG_LENGTHS: Final[dict[bytes, int]] = {
    b"A": 36,
    b"F": 40,
    b"E": 31,
    b"C": 36,
    b"X": 23,
    b"D": 19,
    b"U": 35,
}

FAST_PATH_TYPES: Final[frozenset[bytes]] = frozenset(MSG_LENGTHS.keys())

# Per-type field offsets: {field_name: (byte_offset, byte_width)}.
# Offsets are from the start of the message including the type byte.
_COMMON_HEADER = {
    "stock_locate":    (1,  2),
    "tracking_number": (3,  2),
    "timestamp":       (5,  6),
}

FIELD_OFFSETS: Final[dict[bytes, dict[str, tuple[int, int]]]] = {
    b"A": {
        **_COMMON_HEADER,
        "order_id":  (11, 8),
        "side":      (19, 1),
        "shares":    (20, 4),
        "stock":     (24, 8),
        "price":     (32, 4),
    },
    b"F": {
        **_COMMON_HEADER,
        "order_id":  (11, 8),
        "side":      (19, 1),
        "shares":    (20, 4),
        "stock":     (24, 8),
        "price":     (32, 4),
        "mpid":      (36, 4),
    },
    b"E": {
        **_COMMON_HEADER,
        "order_id":         (11, 8),
        "executed_shares":  (19, 4),
        "match_number":     (23, 8),
    },
    b"C": {
        **_COMMON_HEADER,
        "order_id":         (11, 8),
        "executed_shares":  (19, 4),
        "match_number":     (23, 8),
        "printable":        (31, 1),
        "price":            (32, 4),
    },
    b"X": {
        **_COMMON_HEADER,
        "order_id":           (11, 8),
        "cancelled_shares":   (19, 4),
    },
    b"D": {
        **_COMMON_HEADER,
        "order_id":  (11, 8),
    },
    b"U": {
        **_COMMON_HEADER,
        "orig_order_id":  (11, 8),
        "new_order_id":   (19, 8),
        "shares":         (27, 4),
        "price":          (31, 4),
    },
}
