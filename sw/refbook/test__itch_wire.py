"""Tests for _itch_wire.py — ITCH 5.0 message length and offset constants.

Run from /home/popes/nanobook/sw/refbook:
  pytest test__itch_wire.py -v
"""
from __future__ import annotations

import sys
sys.path.insert(0, ".")

from _itch_wire import MSG_LENGTHS, FAST_PATH_TYPES, FIELD_OFFSETS


def test_msg_lengths_match_spec():
    assert MSG_LENGTHS == {
        b"A": 36,  # Add Order
        b"F": 40,  # Add Order with MPID
        b"E": 31,  # Order Executed
        b"C": 36,  # Order Executed with Price
        b"X": 23,  # Order Cancel
        b"D": 19,  # Order Delete
        b"U": 35,  # Order Replace
    }


def test_fast_path_types_covers_all_lengths():
    assert FAST_PATH_TYPES == frozenset({b"A", b"F", b"E", b"C", b"X", b"D", b"U"})
    assert FAST_PATH_TYPES == frozenset(MSG_LENGTHS.keys())


def test_add_field_offsets():
    # ITCH 5.0 'A' message layout (after 1-byte type, big-endian):
    # offset 1:  stock_locate     (uint16, 2B)
    # offset 3:  tracking_number  (uint16, 2B)
    # offset 5:  timestamp        (uint48, 6B)
    # offset 11: order_id         (uint64, 8B)
    # offset 19: side             ('B' or 'S', 1B)
    # offset 20: shares           (uint32, 4B)
    # offset 24: stock            (8 ASCII bytes)
    # offset 32: price            (uint32, 4B fixed-point, 4 decimals)
    # total: 36
    a = FIELD_OFFSETS[b"A"]
    assert a["stock_locate"]    == (1,  2)
    assert a["tracking_number"] == (3,  2)
    assert a["timestamp"]       == (5,  6)
    assert a["order_id"]        == (11, 8)
    assert a["side"]            == (19, 1)
    assert a["shares"]          == (20, 4)
    assert a["stock"]           == (24, 8)
    assert a["price"]           == (32, 4)


def test_delete_field_offsets():
    d = FIELD_OFFSETS[b"D"]
    # offset 1: stock_locate (2B), 3: tracking (2B), 5: ts (6B), 11: order_id (8B)
    # total: 19
    assert d["stock_locate"]    == (1,  2)
    assert d["tracking_number"] == (3,  2)
    assert d["timestamp"]       == (5,  6)
    assert d["order_id"]        == (11, 8)


def test_replace_field_offsets():
    u = FIELD_OFFSETS[b"U"]
    # offset 1: stock_locate, 3: tracking, 5: ts, 11: orig_order_id (8B),
    # 19: new_order_id (8B), 27: shares (4B), 31: price (4B)
    # total: 35
    assert u["stock_locate"]      == (1,  2)
    assert u["tracking_number"]   == (3,  2)
    assert u["timestamp"]         == (5,  6)
    assert u["orig_order_id"]     == (11, 8)
    assert u["new_order_id"]      == (19, 8)
    assert u["shares"]            == (27, 4)
    assert u["price"]             == (31, 4)
