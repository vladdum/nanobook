"""Tests for sw.m05_tools.symbol_slice — anchor-detection on a tiny synthetic
ITCH stream. Constructs length-prefixed fake messages with the right type
byte + symbol_id field; the body is otherwise zero-filled (the slicer only
inspects type byte and symbol_id, not the rest of the fast-path fields)."""
from __future__ import annotations

from pathlib import Path

from sw.refbook._itch_wire import MSG_LENGTHS
from sw.m05_tools.symbol_slice import slice_to_symbol_fastpath
from sw.replay.replay import _open_input


def _make_msg(type_byte: bytes, symbol_id: int) -> bytes:
    """Build a length-prefixed ITCH message of the right size for `type_byte`,
    with `stock_locate` (symbol_id) at offset 1..3 (big-endian u16)."""
    if type_byte in MSG_LENGTHS:
        body_len = MSG_LENGTHS[type_byte]
    else:
        # Slow-path types we use in the test:
        #   'R' Stock Directory = 39 bytes
        body_len = {b"R": 39}[type_byte]
    body = bytearray(body_len)
    body[0:1] = type_byte
    body[1:3] = symbol_id.to_bytes(2, "big")
    return body_len.to_bytes(2, "big") + bytes(body)


def _make_add_message(symbol_id: int, order_id: int = 1) -> bytes:
    """ITCH 'A' (Add Order, no MPID) with side='B' so parse_one accepts it."""
    msg = bytearray(MSG_LENGTHS[b"A"])
    msg[0:1] = b"A"
    msg[1:3] = symbol_id.to_bytes(2, "big")
    msg[11:19] = order_id.to_bytes(8, "big")
    msg[19:20] = b"B"  # side
    msg[20:24] = (1).to_bytes(4, "big")  # shares
    msg[32:36] = (1000).to_bytes(4, "big")  # price
    return len(msg).to_bytes(2, "big") + bytes(msg)


def _make_delete_message(symbol_id: int, order_id: int = 1) -> bytes:
    """ITCH 'D' (Delete Order)."""
    msg = bytearray(MSG_LENGTHS[b"D"])
    msg[0:1] = b"D"
    msg[1:3] = symbol_id.to_bytes(2, "big")
    msg[11:19] = order_id.to_bytes(8, "big")
    return len(msg).to_bytes(2, "big") + bytes(msg)


def test_slice_finds_anchor_and_captures_n(tmp_path: Path) -> None:
    """Stream layout:
        [R sym=1] [R sym=2] [R sym=3] [R sym=4] [R sym=5]
        [A sym=42 oid=10]   <-- anchor for symbol_id=42
        [D sym=42 oid=10]
        [A sym=99 oid=11]   <-- past the n=2 cutoff, should NOT be captured
    With n=2 we should capture the A and the D, byte-for-byte.
    """
    src = tmp_path / "src.itch"
    dst = tmp_path / "out.itch.zst"

    stream = bytearray()
    # Five slow-path 'R' messages for various symbols.
    for sym in (1, 2, 3, 4, 5):
        stream += _make_msg(b"R", sym)
    # Anchor: A for symbol 42.
    stream += _make_add_message(42, order_id=10)
    # Within the n=2 window: D for symbol 42.
    stream += _make_delete_message(42, order_id=10)
    # Past the n=2 window: A for symbol 99.
    stream += _make_add_message(99, order_id=11)

    src.write_bytes(bytes(stream))

    n = slice_to_symbol_fastpath(src, dst, symbol_id=42, n_msgs=2)
    assert n == 2, f"expected 2 messages captured, got {n}"

    # Re-open the slice and walk length prefixes — must yield 2 messages.
    with _open_input(dst) as fp:
        records: list[tuple[bytes, int]] = []
        while True:
            hdr = fp.read(2)
            if len(hdr) < 2:
                break
            ln = int.from_bytes(hdr, "big")
            body = fp.read(ln)
            assert len(body) == ln
            records.append((body[0:1], int.from_bytes(body[1:3], "big")))
    assert records == [(b"A", 42), (b"D", 42)], f"unexpected records: {records}"


def test_slice_skips_slow_path_for_anchor_detection(tmp_path: Path) -> None:
    """Even if a slow-path 'R' message has a matching stock_locate, anchor
    detection requires a *fast-path* type. Confirm a stream with an R-for-42
    followed by an A-for-42 anchors at the A, not the R."""
    src = tmp_path / "src.itch"
    dst = tmp_path / "out.itch"  # no zstd suffix -> raw

    stream = bytearray()
    stream += _make_msg(b"R", 42)        # slow-path; anchor must NOT trigger here
    stream += _make_msg(b"R", 7)
    stream += _make_add_message(42, 1)   # this is the anchor
    stream += _make_delete_message(42, 1)
    src.write_bytes(bytes(stream))

    n = slice_to_symbol_fastpath(src, dst, symbol_id=42, n_msgs=2)
    assert n == 2

    raw = dst.read_bytes()
    # First length-prefix should describe an 'A' message of 36 bytes.
    assert int.from_bytes(raw[0:2], "big") == MSG_LENGTHS[b"A"]
    assert raw[2:3] == b"A"


def test_slice_returns_zero_when_anchor_not_found(tmp_path: Path) -> None:
    src = tmp_path / "src.itch"
    dst = tmp_path / "out.itch"
    stream = bytearray()
    stream += _make_add_message(7, 1)
    stream += _make_add_message(8, 2)
    src.write_bytes(bytes(stream))

    n = slice_to_symbol_fastpath(src, dst, symbol_id=99, n_msgs=10)
    assert n == 0
    # Output file is created but zero-length.
    assert dst.exists()
    assert dst.stat().st_size == 0
