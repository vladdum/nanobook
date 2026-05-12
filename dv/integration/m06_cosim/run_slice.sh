#!/usr/bin/env bash
# Run the M06 cosim against a multi-symbol ITCH slice.
#
# This is a skeleton: it expects M06_SLICE_ITCH in the environment OR an
# already-staged slice at the default path below. Phase H of the M06
# plan called for a 100 K-event fast-path window from 2019-03-27; the
# exact slice generator lands with the F.2 follow-up.
#
# Bit-exact comparison vs refbook filtered to the picked-100
# stock_locate set is performed inside tb_cosim.py.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

DEFAULT_SLICE="$REPO_ROOT/data/pcaps/slices/m06_2019-03-27_picked100.itch.zst"
SLICE="${M06_SLICE_ITCH:-$DEFAULT_SLICE}"

if [[ ! -f "$SLICE" ]]; then
    echo "ERROR: M06 slice not found at $SLICE" >&2
    echo "Either export M06_SLICE_ITCH or stage the slice at the default path." >&2
    echo "Slice generator (multi-symbol filter on picked-100) lands with the F.2 follow-up." >&2
    exit 2
fi

echo "[m06_cosim] slice=$SLICE"

export M06_SLICE_ITCH="$SLICE"
export SIM_BUILD="${SIM_BUILD:-sim_build_m06_cosim}"

make -C "$REPO_ROOT/dv/integration/m06_cosim" -f Makefile.cosim 2>&1
