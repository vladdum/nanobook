#!/usr/bin/env bash
# TODO: needs F.2 full — the cosim itself runs once F.2 (squash-and-retry
# on rebase + per-sym ladder address math + full op_sym_idx threading) is
# merged. Until then this script's slice variant (run_slice.sh) is the
# only Phase H runner that can produce meaningful divergence diagnostics.
#
# Phase L — full-day M06 multi-symbol cosim.
#
# Drives every fast-path event for the picked-100 stock_locate set on a
# full NASDAQ ITCH 5.0 trading day through `itch_decoder -> lob_core`
# and bit-compares the emitted TOB stream against `sw/refbook` filtered
# to the same picked set.
#
# Wallclock optimisation: pre-filter the source ITCH file to messages
# whose stock_locate appears in lob_core_sym_init.mem. lob_core's
# sym_idx_lut would have dropped the others anyway, so this is purely a
# runtime win. The bit-exact assertion is unchanged.
#
# Usage: run_full_day.sh [<day>]
# where <day> is one of: 03272019 (default) / 10302019 / 08302019.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DAY="${1:-03272019}"

SRC="$REPO_ROOT/data/pcaps/${DAY}.NASDAQ_ITCH50.gz"
[[ -f "$SRC" ]] || { echo "ERROR: source ITCH file not found at $SRC" >&2; exit 2; }

FILT_DIR="${WORK:-/tmp/m06_fullday}"
mkdir -p "$FILT_DIR"
FILT="$FILT_DIR/${DAY}.picked100.itch.zst"

if [[ ! -f "$FILT" ]]; then
    echo "[m06_fullday] generating filtered stream: $FILT"
    # TODO (F.2 follow-up): land the multi-symbol filter CLI.
    #   python3 -m sw.m06_tools.symbol_slice "$SRC" "$FILT" \
    #       --sym-init hw/ip/lob_core/lob_core_sym_init.mem --filter-only
    echo "ERROR: multi-symbol pre-filter CLI not yet implemented." >&2
    echo "Stage the pre-filtered stream manually at $FILT to proceed." >&2
    exit 2
fi

echo "[m06_fullday] day=$DAY stream=$FILT"
ls -la "$FILT"

export M06_SLICE_ITCH="$FILT"
export SIM_BUILD="sim_build_m06_fullday"

time make -C "$REPO_ROOT/dv/integration/m06_cosim" -f Makefile.cosim 2>&1
