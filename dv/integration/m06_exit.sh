#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# M06 exit gate — scaled to the runnable subset of the plan.
#
# Phases H (multi-symbol cosim), I (book-quake TB) and J (Vivado OOC) are
# deferred (see dv/integration/m06_cosim/README.md and the F.2 deferral
# note in hw/ip/lob_core/lob_core.sv). Steps that would exercise those
# phases are listed below and explicitly skipped with a TODO marker.

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

echo "[5/9] Slice cosim — DEFERRED (Phase H, see dv/integration/m06_cosim/README.md)"
echo "[6/9] Full-day cosim — DEFERRED (Phase H)"
echo "[7/9] Book-quake TB — DEFERRED (Phase I, see dv/integration/m06_bookquake/README.md)"
echo "[8/9] Vivado OOC synth — DEFERRED (Phase J, gated on explicit user approval)"

echo "[9/9] docs/design.md §4.4 amendment"
grep -q "drop-on-rebase" docs/design.md

echo "=== M06 EXIT GATE (partial): PASS ==="
