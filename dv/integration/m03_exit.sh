#!/usr/bin/env bash
# M03 exit-gate. Runs:
#   1. Codegen idempotency
#   2. Full cocotb suite (smoke + per-stage + per-extractor + e2e + throughput + edge_cases)
#   3. Verilator lint
#   4. Vivado OOC synth + Fmax check
# Aborts with a clear message if Vivado is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "[m03_exit] 1/4 codegen idempotency"
make itch-decoder-codegen-check

echo "[m03_exit] 2/4 cocotb suite"
make itch-decoder-test
for tb in mold_strip msg_boundary type_dispatch field_extract endian_swap event_pack \
          extract_add extract_exec extract_cancel extract_delete extract_replace \
          e2e throughput edge_cases; do
    echo "[m03_exit]   - $tb"
    make -C dv/unit/itch_decoder -f "Makefile.$tb" >/dev/null
done

echo "[m03_exit] 3/4 Verilator lint"
make itch-decoder-lint

echo "[m03_exit] 4/4 Vivado OOC synth + Fmax check"
if ! command -v vivado >/dev/null; then
    echo "ERROR: vivado not on PATH. Source settings64.sh first." >&2
    exit 1
fi
mkdir -p hw/synth/itch_decoder/build
( cd hw/synth/itch_decoder && vivado -mode batch -source synth.tcl > build/vivado.log )
python3 hw/synth/itch_decoder/check_timing.py

echo "[m03_exit] PASS"
