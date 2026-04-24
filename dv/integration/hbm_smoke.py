"""On-hardware HBM smoke test: 16 MB write+read via BAR0 trigger."""
import time
import sys
from nanobook import XdmaUser
from nanobook.registers import REG_CONTROL, REG_STATUS, STATUS_HBM_READY, CTRL_HBM_SMOKE_GO

STATUS_HBM_DONE      = 1 << 8
STATUS_HBM_ANY_ERROR = 1 << 9


def main() -> int:
    with XdmaUser(0) as dev:
        deadline = time.time() + 10
        while not (dev.read32(REG_STATUS) & STATUS_HBM_READY):
            if time.time() > deadline:
                print("HBM IP never became ready")
                return 1
            time.sleep(0.01)
        dev.write32(REG_CONTROL, dev.read32(REG_CONTROL) | CTRL_HBM_SMOKE_GO)
        deadline = time.time() + 30
        while not (dev.read32(REG_STATUS) & STATUS_HBM_DONE):
            if time.time() > deadline:
                print("HBM smoke test never completed")
                return 2
            time.sleep(0.05)
        status = dev.read32(REG_STATUS)
        if status & STATUS_HBM_ANY_ERROR:
            print("HBM smoke test reported errors")
            return 3
        print("PASS: 16 MB HBM write+read done, 0 errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
