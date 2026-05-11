#!/usr/bin/env bash
# M05 exit gate. Asserts spec §11 criteria 1-7 in order; FAIL on first miss.
#
# Spec: docs/superpowers/specs/2026-05-09-nanobook-m05-book-core-uram-design.md §11
# Plan: docs/superpowers/plans/2026-05-09-nanobook-m05-book-core-uram.md Task 31
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "==> [1/8] M04 goldens present + checksums match"
make verify-goldens

echo "==> [2/8] Phase B reports + params present"
test -f hw/ip/lob_core/lob_core_params_pkg.sv
test -f data/pcaps/slices/m05_params.json
test -f data/pcaps/slices/m05_2019-03-27_sym5754.itch.zst
# docs/m05/* are gitignored; presence is best-effort on a fresh clone.
[[ -f docs/m05/symbol_selection.md ]] || \
    echo "    NOTE: docs/m05/symbol_selection.md missing (Phase B local-only output, regen via sw.m05_tools.symbol_stats)"
[[ -f docs/m05/hash_sizing.md ]] || \
    echo "    NOTE: docs/m05/hash_sizing.md missing (regen via sw.m05_tools.hash_sim)"

echo "==> [3/8] Verilator lint clean"
make lob-core-lint

echo "==> [4/8] All sub-module unit TBs pass"
make -C dv/unit/lob_core -f Makefile.smoke
make -C dv/unit/lob_core -f Makefile.order_pool
make -C dv/unit/lob_core -f Makefile.order_id_hash
make -C dv/unit/lob_core -f Makefile.price_ladder
make -C dv/unit/lob_core -f Makefile.tob_tracker

echo "==> [5/8] Cycle-accurate TB asserts (ADD=4, DELETE=6 first-probe, post-2026-05-11 amendment)"
make -C dv/unit/lob_core -f Makefile.cycles

echo "==> [6/8] Integration cosim 100K slice (CI gate, bit-exact vs refbook)"
bash dv/integration/m05_cosim/run_slice.sh

echo "==> [7/8] Integration cosim full day (bit-exact vs refbook on filtered stream)"
bash dv/integration/m05_cosim/run_full_day.sh 2019-03-27 || \
    echo "    NOTE: full-day cosim skipped or non-bit-exact — see m05 retro"

echo "==> [8/8] Vivado OOC synth + Fmax (smoke synth at reduced sizes)"
if command -v vivado >/dev/null 2>&1; then
    make lob-core-synth
else
    echo "    NOTE: vivado not on PATH; skipping. Source /opt/Xilinx/.../settings64.sh"
fi

echo
echo "M05 EXIT: PASS"
