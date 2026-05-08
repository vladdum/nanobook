"""Tests for sw/replay/itch_slice.py.

Slicer must:
1. Produce a byte-exact prefix of the input file.
2. Stop after exactly N consecutive ITCH messages.
3. Handle gzip and raw input transparently.
4. Optionally zstd-compress the output.
"""
from __future__ import annotations

import gzip
from pathlib import Path

from sw.replay import itch_slice


def _synthesize_itch_stream(message_lengths: list[int]) -> bytes:
    """Build a length-prefixed stream where each entry is `<u16-be N><N bytes>`."""
    out = bytearray()
    for i, n in enumerate(message_lengths):
        out += n.to_bytes(2, "big")
        out += bytes([(i + 1) & 0xFF] * n)
    return bytes(out)


def test_slice_byte_exact_prefix(tmp_path: Path) -> None:
    src = tmp_path / "in.itch"
    src.write_bytes(_synthesize_itch_stream([36, 31, 19, 23, 35]))
    dst = tmp_path / "out.itch"

    n = itch_slice.slice_first_n(src, dst, count=3, compress=False)

    assert n == 3
    expected = _synthesize_itch_stream([36, 31, 19])
    assert dst.read_bytes() == expected


def test_slice_handles_gzip_input(tmp_path: Path) -> None:
    raw = _synthesize_itch_stream([36, 36, 36])
    src = tmp_path / "in.itch.gz"
    src.write_bytes(gzip.compress(raw))
    dst = tmp_path / "out.itch"

    n = itch_slice.slice_first_n(src, dst, count=2, compress=False)

    assert n == 2
    expected = _synthesize_itch_stream([36, 36])
    assert dst.read_bytes() == expected


def test_slice_emits_zstd_when_compress_true(tmp_path: Path) -> None:
    import zstandard

    src = tmp_path / "in.itch"
    src.write_bytes(_synthesize_itch_stream([36, 36]))
    dst = tmp_path / "out.itch.zst"

    itch_slice.slice_first_n(src, dst, count=2, compress=True)

    decompressed = zstandard.ZstdDecompressor().decompress(dst.read_bytes())
    assert decompressed == _synthesize_itch_stream([36, 36])


def test_slice_short_input_stops_early(tmp_path: Path) -> None:
    src = tmp_path / "in.itch"
    src.write_bytes(_synthesize_itch_stream([36, 31]))
    dst = tmp_path / "out.itch"

    n = itch_slice.slice_first_n(src, dst, count=10, compress=False)

    assert n == 2
    assert dst.read_bytes() == _synthesize_itch_stream([36, 31])
