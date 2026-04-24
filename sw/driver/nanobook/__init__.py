import os
import struct
from pathlib import Path


class XdmaUser:
    def __init__(self, dev_index: int = 0):
        path = Path(f"/dev/xdma{dev_index}_user")
        if not path.exists():
            raise FileNotFoundError(f"{path} not present — is the shell bitstream loaded?")
        self._fd = os.open(str(path), os.O_RDWR)

    def read32(self, offset: int) -> int:
        os.lseek(self._fd, offset, os.SEEK_SET)
        return struct.unpack("<I", os.read(self._fd, 4))[0]

    def write32(self, offset: int, value: int) -> None:
        os.lseek(self._fd, offset, os.SEEK_SET)
        os.write(self._fd, struct.pack("<I", value & 0xFFFF_FFFF))

    def close(self) -> None:
        os.close(self._fd)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
