#!/usr/bin/env bash
# M1 exit criteria gate — run all five criteria back-to-back.
# Exit 0 only if all pass. Produces build/m01_exit.log when called with tee.
set -euo pipefail

step() { echo; echo "== $* =="; }

step "1. lspci shows Alveo U50"
sudo lspci -vv -d 10ee: | tee /tmp/m01_lspci.txt
grep -q "Region 0: Memory at" /tmp/m01_lspci.txt

step "2. BAR0 registers round-trip (ID/VERSION/CONTROL/SHA)"
python3 dv/integration/xdma_enum.py

step "2b. FPGA git SHA matches HEAD"
python3 dv/integration/git_sha_check.py

step "3. HBM 16 MB write+read smoke test"
python3 dv/integration/hbm_smoke.py

step "4. 10G loopback BER test (60 s @ 9.9 Gb/s)"
sudo python3 dv/integration/eth10g_ber.py

step "5. ITCH pcaps present and checksummed"
make verify-pcaps

echo
echo "================================="
echo "M01 EXIT CRITERIA: ALL PASS"
echo "================================="
