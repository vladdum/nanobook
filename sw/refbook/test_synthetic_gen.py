"""Byte-level determinism tests for synthetic_gen.py.

Run: pytest sw/refbook/test_synthetic_gen.py -v
"""
from __future__ import annotations

import hashlib
from synthetic_gen import generate_book_events, generate_itch_bytes


def test_book_events_deterministic_small():
    a = list(generate_book_events(seed=42, n_symbols=10, n_events=1000))
    b = list(generate_book_events(seed=42, n_symbols=10, n_events=1000))
    assert a == b


def test_book_events_packed_bytes_byte_identical():
    a = b"".join(e.pack() for e in generate_book_events(42, 10, 1000))
    b = b"".join(e.pack() for e in generate_book_events(42, 10, 1000))
    assert a == b
    assert len(a) == 1000 * 32


def test_itch_bytes_deterministic():
    a = generate_itch_bytes(seed=42, n_symbols=10, n_events=1000)
    b = generate_itch_bytes(seed=42, n_symbols=10, n_events=1000)
    assert a == b


def test_seeded_sha256_known_value():
    data = b"".join(e.pack() for e in generate_book_events(42, 10, 1000))
    h = hashlib.sha256(data).hexdigest()
    # The expected hash is committed here. Bumping it requires an intentional PR
    # that also updates sw/refbook/test/reproducibility_expected.sha256.
    # On first run: print(h) and paste back into this assertion.
    assert h == "2dd5a4253681afb242b119d090437e50771ea83a6d385096f037db2fc7b92f74", \
        f"bump expected SHA: {h}"


# --- Phase B (M03) additions ---
from _itch_wire import MSG_LENGTHS  # noqa: E402


def test_encode_itch_fast_path_lengths():
    """Each fast-path type encoded by _encode_itch must match the ITCH 5.0 spec length."""
    from synthetic_gen import _encode_itch, BookEvent, EV_ADD, EV_DELETE, EV_CANCEL, EV_EXEC

    # ADD
    ev = BookEvent(EV_ADD, 0, 1, 1_000_000, 100, 42, 1)
    assert len(_encode_itch(ev)) == MSG_LENGTHS[b"A"], "ADD length mismatch"

    # DELETE
    ev = BookEvent(EV_DELETE, 0, 1, 0, 0, 42, 2)
    assert len(_encode_itch(ev)) == MSG_LENGTHS[b"D"], "DELETE length mismatch"

    # CANCEL
    ev = BookEvent(EV_CANCEL, 0, 1, 0, 30, 42, 3)
    assert len(_encode_itch(ev)) == MSG_LENGTHS[b"X"], "CANCEL length mismatch"

    # EXEC
    ev = BookEvent(EV_EXEC, 0, 1, 0, 50, 42, 4)
    assert len(_encode_itch(ev)) == MSG_LENGTHS[b"E"], "EXEC length mismatch"


def test_itch_round_trip_fast_path():
    """For each fast-path EventType, encode → decode reproduces the BookEvent."""
    from synthetic_gen import (
        _encode_itch, _decode_itch, BookEvent,
        EV_ADD, EV_DELETE, EV_CANCEL, EV_EXEC, EV_EXECPX,
    )

    test_events = [
        BookEvent(EV_ADD,    0, 1, 1_000_000, 100, 42, 1),
        BookEvent(EV_ADD,    1, 7,   500_000,  50, 99, 2),
        BookEvent(EV_DELETE, 0, 1, 0, 0, 42, 3),
        BookEvent(EV_CANCEL, 0, 1, 0, 30, 42, 4),
        BookEvent(EV_EXEC,   0, 1, 0, 50, 42, 5),
        BookEvent(EV_EXECPX, 0, 1, 1_234_567, 25, 42, 6),
    ]
    for ev in test_events:
        encoded = _encode_itch(ev)
        decoded = _decode_itch(encoded)
        # Decoded BookEvent must match original on the fields the decoder
        # reconstructs. Side is only meaningful for ADD; tracking_number,
        # timestamp, MPID, etc. are wire-only (no BookEvent representation).
        assert decoded.type       == ev.type,       f"type mismatch on {ev}"
        assert decoded.symbol_id  == ev.symbol_id,  f"symbol_id mismatch on {ev}"
        assert decoded.order_id   == ev.order_id,   f"order_id mismatch on {ev}"
        # ts48 is what the decoder reconstructs (lower 48 bits)
        assert decoded.ingress_ts == (ev.ingress_ts & ((1 << 48) - 1)), \
            f"ingress_ts mismatch on {ev}"
        if ev.type == EV_ADD:
            assert decoded.side   == ev.side,   f"side mismatch on {ev}"
            assert decoded.price  == ev.price,  f"price mismatch on {ev}"
            assert decoded.shares == ev.shares, f"shares mismatch on {ev}"
        elif ev.type in (EV_CANCEL, EV_EXEC):
            assert decoded.shares == ev.shares, f"shares mismatch on {ev}"
        elif ev.type == EV_EXECPX:
            assert decoded.price  == ev.price,  f"price mismatch on {ev}"
            assert decoded.shares == ev.shares, f"shares mismatch on {ev}"


def test_encode_itch_slow_path_lengths():
    from synthetic_gen import _encode_itch_slow_path

    assert _encode_itch_slow_path(b"R") == b"R" + b"\xff" * 38, "R length"
    assert _encode_itch_slow_path(b"S") == b"S" + b"\xff" * 11, "S length"
    assert _encode_itch_slow_path(b"H") == b"H" + b"\xff" * 24, "H length"
