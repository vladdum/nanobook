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
