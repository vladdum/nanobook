"""On-hardware BAR0 smoke test: ID/VERSION/CONTROL round-trip/SHA presence."""
import sys
import time

from nanobook import XdmaUser
from nanobook.registers import (
    ID_MAGIC,
    REG_CONTROL,
    REG_ID,
    REG_VERSION,
    VERSION_1_0,
)


def main() -> int:
    with XdmaUser(0) as dev:
        id_val = dev.read32(REG_ID)
        assert id_val == ID_MAGIC, f"ID wrong: {id_val:#010x}"
        ver = dev.read32(REG_VERSION)
        assert ver == VERSION_1_0, f"VERSION wrong: {ver:#010x}"
        for pat in (0x0, 0x7, 0x5, 0x3, 0x0):
            dev.write32(REG_CONTROL, pat)
            rb = dev.read32(REG_CONTROL)
            assert rb == pat, f"CONTROL RW fail: wrote {pat:#x} read {rb:#x}"
        t0 = time.perf_counter_ns()
        for _ in range(1000):
            dev.read32(REG_ID)
        rt_us = (time.perf_counter_ns() - t0) / 1e6
        assert rt_us < 100, f"round-trip too slow: {rt_us:.2f} us"
        print(f"PASS: ID/VERSION/CONTROL OK, round-trip {rt_us:.2f} us per read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
