"""On-hardware check that GIT_SHA_LO/HI (BAR0 0x20/0x24) match the running HEAD.

The synthesized SHA is baked in at build time via build_sha.vh.  This script
reads it back over BAR0 and compares against `git rev-parse HEAD`.
"""
import subprocess
import sys

from nanobook import XdmaUser
from nanobook.registers import REG_GIT_SHA_HI, REG_GIT_SHA_LO


def head_sha() -> int:
    """Return the 64-bit integer representation of the current HEAD SHA."""
    sha_hex = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True
    ).strip()
    return int(sha_hex, 16)


def main() -> int:
    ref = head_sha()
    ref_lo = ref & 0xFFFF_FFFF
    ref_hi = (ref >> 32) & 0xFFFF_FFFF

    with XdmaUser(0) as dev:
        hw_lo = dev.read32(REG_GIT_SHA_LO)
        hw_hi = dev.read32(REG_GIT_SHA_HI)

    if hw_lo != ref_lo or hw_hi != ref_hi:
        print(
            f"FAIL: SHA mismatch\n"
            f"  HW:  {hw_hi:08x}{hw_lo:08x}\n"
            f"  git: {ref_hi:08x}{ref_lo:08x}"
        )
        return 1

    print(f"PASS: GIT_SHA matches HEAD ({ref_hi:08x}{ref_lo:08x})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
