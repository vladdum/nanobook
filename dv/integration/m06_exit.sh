#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# M06 exit gate.
#
# Phases H (multi-symbol cosim, slice variant), I (book-quake TB), and J
# (Vivado OOC) are now exercised here. The full-day cosim variant of
# Phase H remains a Phase L / nightly-CI item (see retrospective).
# Phase J runs under the no-synthesis-without-permission preference —
# `make lob-core-synth` only invokes Vivado when V_RUN_SYNTH=1 is set.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

echo "=== M06 EXIT GATE (partial — see retrospective for deferrals) ==="

echo "[1/9] M05 regression — Verilator-only subset"
# Do NOT invoke dv/integration/m05_exit.sh directly: its step [8] runs
# Vivado OOC synthesis, which is gated on explicit user approval per
# the no-synthesis-without-permission preference. Run only the
# Verilator-based pieces of M05's gate here.
make verify-goldens
make lob-core-lint
make -C dv/unit/lob_core -f Makefile.smoke
make -C dv/unit/lob_core -f Makefile.order_pool
make -C dv/unit/lob_core -f Makefile.order_id_hash
make -C dv/unit/lob_core -f Makefile.price_ladder
make -C dv/unit/lob_core -f Makefile.tob_tracker
make -C dv/unit/lob_core -f Makefile.cycles

echo "[2/9] Phase A artifacts present"
test -f hw/ip/lob_core/lob_core_sym_pkg.sv
test -f hw/ip/lob_core/lob_core_sym_init.mem

echo "[3/9] Unit TBs"
for tb in order_pool price_ladder tob_tracker order_id_hash \
          sym_idx_lut per_sym_state \
          smoke cycles lob_core_cycles_m06 lob_core_rebase; do
    echo "  -> $tb"
    make -C dv/unit/lob_core -f Makefile.$tb > /dev/null
done

echo "[4/9] CLZ_LATENCY assertion (covered by tb_lob_core_cycles_m06)"
# Already exercised in step [3].

echo "[5/9] Slice cosim — multi-symbol picked-100 (Phase H)"
# Requires the filtered slice at data/pcaps/slices/m06_2019-03-27_picked100.itch.zst
# (generate with `make m06-gen-slice`). The cosim TB asserts bit-exact
# RTL TOB-delta sequence vs refbook filtered to the same picked-100
# locate set.
if [ -f data/pcaps/slices/m06_2019-03-27_picked100.itch.zst ]; then
    bash dv/integration/m06_cosim/run_slice.sh > /dev/null
else
    echo "  SKIPPED: m06 slice not staged; run \`make m06-gen-slice\` first"
fi

echo "[6/9] Full-day cosim — DEFERRED (M11 — nightly CI once baseline wallclock is known)"

echo "[7/9] Book-quake TB (Phase I)"
python3 -m sw.m06_tools.synth_bookquake --out /tmp/m06_exit_bookquake.bin \
    --n-syms 10 --per-sym-orders 5 > /dev/null
M06_BQ_STREAM=/tmp/m06_exit_bookquake.bin \
    make -C dv/integration/m06_bookquake -f Makefile.bookquake > /dev/null

echo "[8/9] Vivado OOC synth (Phase J, opt-in via V_RUN_SYNTH=1)"
if [ "${V_RUN_SYNTH:-0}" = "1" ]; then
    make lob-core-synth
else
    echo "  SKIPPED: set V_RUN_SYNTH=1 to run (last verified WNS = +0.080 ns,"
    echo "  PR #43 — fix(m06): infer UltraRAM for hash and price_ladder)"
fi

echo "[9/9] docs/design.md §4.4 amendment"
grep -q "drop-on-rebase" docs/design.md

echo "=== M06 EXIT GATE: PASS ==="
