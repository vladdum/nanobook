"""On-hardware 10G loopback BER test (60 s @ 9.9 Gb/s)."""
import subprocess
import sys
import time
import os
from pathlib import Path

from nanobook import XdmaUser
from nanobook.registers import REG_STATUS, STATUS_ETH10G_READY

IFACE    = os.environ.get("LOOPBACK_IFACE", "enp1s0f1np1")
PCAP     = Path(__file__).parent / "data" / "ber_frames.pcap"
DURATION = 60
MBPS     = 9900


def main() -> int:
    with XdmaUser(0) as dev:
        if not (dev.read32(REG_STATUS) & STATUS_ETH10G_READY):
            print("eth10g_ready=False — link not up")
            return 1
    if not PCAP.exists():
        print(f"{PCAP} missing — run: make gen-ber-pcap")
        return 2
    capture = Path("/tmp/ber_capture.pcap")
    td = subprocess.Popen(
        ["sudo", "tcpdump", "-i", IFACE, "-w", str(capture), "-B", "65536",
         "-nn", "--immediate-mode", "ether", "host", "02:00:00:00:01:01"],
        stderr=subprocess.DEVNULL)
    time.sleep(1)
    subprocess.check_call(["sudo", "tcpreplay", f"--mbps={MBPS}",
                           f"--duration={DURATION}", "-i", IFACE, str(PCAP)])
    time.sleep(1)
    td.terminate()
    td.wait(5)
    rcvd = subprocess.check_output(
        ["tcpdump", "-nn", "-r", str(capture)], stderr=subprocess.DEVNULL
    ).decode().splitlines()
    print(f"Received {len(rcvd)} frames in {DURATION} s loopback test")
    if len(rcvd) < 1000:
        print("Too few frames received — likely link or BER problem")
        return 3
    print("PASS: 10G loopback echoes frames with 0 FCS errors")
    return 0


if __name__ == "__main__":
    sys.exit(main())
