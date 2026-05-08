#!/usr/bin/env bash
# Run M04 cosim on all 3 committed slices; diff each.
# Used by `make m04-cosim-slice` and the cosim-slice CI job.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SLICES_DIR="$REPO_ROOT/data/pcaps/slices"
WORK="${WORK:-/tmp/m04_cosim}"
mkdir -p "$WORK"

failed=0
for day in 03272019 10302019 08302019; do
    slice="$SLICES_DIR/${day}.itch.head100k.zst"
    [[ -f "$slice" ]] || { echo "MISSING $slice"; exit 2; }

    actual="$WORK/${day}.actual.bin"
    actual_slow="$WORK/${day}.actual.slow"
    expected="$WORK/${day}.expected.bin"
    expected_slow="$WORK/${day}.expected.slow"

    echo "[m04_cosim] running $day"
    # Stream stdout+stderr so failures surface immediately in CI logs.
    COSIM_ITCH="$slice" COSIM_OUT="$actual" COSIM_OUT_SLOW="$actual_slow" \
      make -C "$REPO_ROOT/dv/integration/m04_cosim" -f Makefile.cosim 2>&1

    PYTHONPATH="$REPO_ROOT${PYTHONPATH:+:$PYTHONPATH}" \
      python3 "$REPO_ROOT/dv/integration/m04_cosim/_gen_expected.py" \
        "$slice" "$expected" "$expected_slow"

    if ! python3 -m sw.replay.event_diff \
         "$actual" "$expected" \
         --actual-slow "$(cat "$actual_slow")" \
         --expected-slow "$(cat "$expected_slow")" \
         --source-pcap "$slice"; then
        failed=1
    fi
done

exit "$failed"
