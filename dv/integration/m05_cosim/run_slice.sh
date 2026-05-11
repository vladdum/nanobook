#!/usr/bin/env bash
# Run the M05 cosim against the committed 100K slice.
#
# Resolves the symbol_id from docs/m05/params.json (authoritative for the
# Phase B selection) and falls back to data/pcaps/slices/m05_params.json
# for CI runners that don't carry the docs tree (e.g., minimal-clone).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

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
SLICE="$REPO_ROOT/data/pcaps/slices/m05_2019-03-27_sym${SYMBOL_ID}.itch.zst"

if [[ ! -f "$SLICE" ]]; then
    echo "ERROR: M05 slice not found at $SLICE" >&2
    echo "Generate it via: python3 -m sw.m05_tools.symbol_slice ..." >&2
    exit 2
fi

echo "[m05_cosim] symbol_id=$SYMBOL_ID slice=$SLICE"

export M05_SLICE_ITCH="$SLICE"
export M05_SYMBOL_ID="$SYMBOL_ID"

make -C "$REPO_ROOT/dv/integration/m05_cosim" -f Makefile.cosim 2>&1
