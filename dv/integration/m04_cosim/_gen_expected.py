"""Helper: generate expected_events.bin + expected_slow_count.txt from a slice.

Used by run_slices.sh and m04_exit.sh. The Phase B Python parser is the
reference; this script frames the per-message decode + slow-path bookkeeping
for the diff harness.
"""
from __future__ import annotations

import sys
from pathlib import Path

from sw.replay import event_bin, itch_parser
from sw.replay.replay import _open_input


def main() -> int:
    src = Path(sys.argv[1])
    expected_path = Path(sys.argv[2])
    expected_slow_path = Path(sys.argv[3])

    slow = 0
    with _open_input(src) as fp, expected_path.open("wb") as ofp:
        while True:
            hdr = fp.read(2)
            if len(hdr) < 2:
                break
            n = int.from_bytes(hdr, "big")
            msg = fp.read(n)
            if len(msg) < n:
                break
            if msg[:1] == b"U":
                event_bin.write(ofp, itch_parser._parse_replace_delete_half(msg))
                event_bin.write(ofp, itch_parser._parse_replace_add_half(msg))
            else:
                ev = itch_parser.parse_one(msg)
                if ev is None:
                    slow += 1
                else:
                    event_bin.write(ofp, ev)

    expected_slow_path.write_text(str(slow))
    return 0


if __name__ == "__main__":
    sys.exit(main())
