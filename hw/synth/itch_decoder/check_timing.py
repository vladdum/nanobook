"""Parse Vivado OOC timing report; assert Fmax >= 250 MHz and zero critical warnings.

Run after `vivado -mode batch -source synth.tcl`. Returns 0 on PASS, 1 on FAIL.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    rpt = Path("hw/synth/itch_decoder/build/timing_summary.rpt")
    if not rpt.exists():
        print(f"ERROR: {rpt} not found — run synth.tcl first", file=sys.stderr)
        return 1
    text = rpt.read_text()
    m = re.search(r"Setup\s*:.*?Worst Slack\s+(-?[\d.]+)ns", text)
    if not m:
        print("ERROR: WNS not found in timing report", file=sys.stderr)
        return 1
    wns = float(m.group(1))
    print(f"WNS: {wns} ns ({'PASS' if wns >= 0 else 'FAIL'} 250 MHz target)")
    if wns < 0:
        return 1

    log = Path("hw/synth/itch_decoder/build/vivado.log")
    if log.exists():
        crit = len(re.findall(r"^CRITICAL WARNING:", log.read_text(), re.MULTILINE))
        print(f"Critical warnings: {crit} ({'PASS' if crit == 0 else 'FAIL'})")
        if crit > 0:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
