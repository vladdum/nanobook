#!/usr/bin/env bash
# M04 exit-gate. Runs:
#   1. Pcap SHA verify
#   2. Python parser pytest suite
#   3. Slice-regeneration idempotency check (committed slices match pinned inputs)
#   4. CI-equivalent cosim on the 3 committed 100K-msg slices
#   5. Full 10M-msg cosim per pcap (the main coverage)
#   6. Carry-over: m03_exit.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
WORK="/tmp/m04_exit"
mkdir -p "$WORK"

echo "[m04_exit] 1/6 pcap SHA verify"
make verify-pcaps

echo "[m04_exit] 2/6 sw/replay pytest"
python3 -m pytest sw/replay/ -q

echo "[m04_exit] 3/6 slice idempotency"
for day in 03272019 10302019 08302019; do
    python3 -m sw.replay.itch_slice \
      "data/pcaps/${day}.NASDAQ_ITCH50.gz" \
      "${WORK}/${day}.itch.head100k.zst" \
      -n 100000
    if ! cmp -s "${WORK}/${day}.itch.head100k.zst" \
                "data/pcaps/slices/${day}.itch.head100k.zst"; then
        echo "ERROR: regenerated slice differs from committed for $day" >&2
        exit 1
    fi
done

echo "[m04_exit] 4/6 cosim-slice"
bash dv/integration/m04_cosim/run_slices.sh

echo "[m04_exit] 5/6 full 10M-msg cosim per pcap"
for day in 03272019 10302019 08302019; do
    src="data/pcaps/${day}.NASDAQ_ITCH50.gz"
    actual="${WORK}/${day}.10m.actual.bin"
    actual_slow="${WORK}/${day}.10m.actual.slow"
    expected="${WORK}/${day}.10m.expected.bin"
    expected_slow="${WORK}/${day}.10m.expected.slow"

    echo "[m04_exit]   $day: cocotb (10M msgs)"
    COSIM_ITCH="$src" COSIM_OUT="$actual" COSIM_OUT_SLOW="$actual_slow" \
      COSIM_MAX_MSGS=10000000 \
      make -C dv/integration/m04_cosim -f Makefile.cosim >/dev/null

    echo "[m04_exit]   $day: python parser (10M msgs)"
    python3 -m sw.replay.itch_slice "$src" "${WORK}/${day}.10m.itch" \
      -n 10000000 --no-compress
    python3 dv/integration/m04_cosim/_gen_expected.py \
      "${WORK}/${day}.10m.itch" "$expected" "$expected_slow"

    echo "[m04_exit]   $day: diff"
    python3 -m sw.replay.event_diff "$actual" "$expected" \
      --actual-slow "$(cat "$actual_slow")" \
      --expected-slow "$(cat "$expected_slow")" \
      --source-pcap "$src"
done

echo "[m04_exit] 6/6 carry-over: m03_exit.sh"
if [[ -x dv/integration/m03_exit.sh ]]; then
    bash dv/integration/m03_exit.sh
else
    echo "[m04_exit]   (m03_exit.sh not present; carry-over skipped)"
fi

echo "[m04_exit] PASS"
