#!/usr/bin/env bash
# Phase J — full-day M05 cosim.
#
# Drives every fast-path event for the chosen symbol on a full NASDAQ
# ITCH 5.0 trading day through `itch_decoder -> lob_core` and bit-
# compares the emitted TOB stream against `sw/refbook` filtered to the
# same symbol.
#
# Wallclock optimisation: pre-filter the source ITCH file to messages
# matching the chosen symbol_id only. lob_core's RTL symbol filter would
# have dropped the others anyway, so this is purely a runtime win
# (~100x: from ~3 hr cocotb wall down to ~30 s on a top-50 symbol).
# The bit-exact assertion is unchanged — we still observe every TOB
# delta the chosen symbol's events would have produced over the day.
#
# Usage: run_full_day.sh [<day>]
# where <day> is one of: 03272019 (default) / 10302019 / 08302019.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DAY="${1:-03272019}"

PARAMS_DOC="$REPO_ROOT/docs/m05/params.json"
PARAMS_CI="$REPO_ROOT/data/pcaps/slices/m05_params.json"
if [[ -f "$PARAMS_DOC" ]]; then
    PARAMS_FILE="$PARAMS_DOC"
elif [[ -f "$PARAMS_CI" ]]; then
    PARAMS_FILE="$PARAMS_CI"
else
    echo "ERROR: no params.json found at $PARAMS_DOC or $PARAMS_CI" >&2
    exit 2
fi
SYMBOL_ID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['symbol_id'])" "$PARAMS_FILE")"

SRC="$REPO_ROOT/data/pcaps/${DAY}.NASDAQ_ITCH50.gz"
[[ -f "$SRC" ]] || { echo "ERROR: source ITCH file not found at $SRC" >&2; exit 2; }

# Cached pre-filtered file — gitignored, regenerated on demand.
FILT_DIR="${WORK:-/tmp/m05_fullday}"
mkdir -p "$FILT_DIR"
FILT="$FILT_DIR/${DAY}.sym${SYMBOL_ID}.itch.zst"

if [[ ! -f "$FILT" ]]; then
    echo "[m05_fullday] generating filtered stream: $FILT"
    cd "$REPO_ROOT"
    python3 -m sw.m05_tools.symbol_slice "$SRC" "$FILT" \
        --symbol "$SYMBOL_ID" --filter-only
    cd - >/dev/null
fi

echo "[m05_fullday] day=$DAY symbol_id=$SYMBOL_ID stream=$FILT"
ls -la "$FILT"

export M05_SLICE_ITCH="$FILT"
export M05_SYMBOL_ID="$SYMBOL_ID"

# Fresh sim_build to avoid contention with run_slice.sh's build dir.
export SIM_BUILD="sim_build_m05_fullday"

time make -C "$REPO_ROOT/dv/integration/m05_cosim" -f Makefile.cosim 2>&1
