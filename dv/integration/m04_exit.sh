#!/usr/bin/env bash
# M04 exit-gate. Runs:
#   1. Pcap SHA verify
#   2. Python parser pytest suite
#   3. Slice-regeneration idempotency check (committed slices match pinned inputs)
#   4. CI-equivalent cosim on the 3 committed 100K-msg slices
#   5. Full 10M-msg cosim per pcap (the main coverage)
#   6. Carry-over: m03_exit.sh
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
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

echo "[m04_exit] 5/6 full 10M-msg cosim per pcap (3 days in parallel; threaded model)"
# Step 5 used to run 3 days × ~90 min sequentially. The 3 cocotb invocations
# are independent (distinct COSIM_OUT, distinct sim_build via COSIM_TAG), so
# we fan them out and join with `wait`. Verilator builds a 4-thread model
# (set V_THREADS in the sub-make if you want to override).
RUN5_DAYS=(03272019 10302019 08302019)
declare -a RUN5_PIDS=()
declare -a RUN5_LOGS=()
for day in "${RUN5_DAYS[@]}"; do
    src="${REPO_ROOT}/data/pcaps/${day}.NASDAQ_ITCH50.gz"
    actual="${WORK}/${day}.10m.actual.bin"
    actual_slow="${WORK}/${day}.10m.actual.slow"
    log="${WORK}/${day}.10m.cosim.log"
    RUN5_LOGS+=("$log")
    echo "[m04_exit]   $day: launching cocotb (10M msgs, log=$log)"
    (
        COSIM_ITCH="$src" COSIM_OUT="$actual" COSIM_OUT_SLOW="$actual_slow" \
          COSIM_MAX_MSGS=10000000 COSIM_TAG="$day" \
          make -C "${REPO_ROOT}/dv/integration/m04_cosim" -f Makefile.cosim
    ) >"$log" 2>&1 &
    RUN5_PIDS+=("$!")
done

echo "[m04_exit]   waiting on ${#RUN5_PIDS[@]} cocotb runs..."
RUN5_START=$(date +%s)
RUN5_HB=60   # heartbeat every 60s — proves the orchestrator is alive even when
             # all per-day cocotb logs are mid-sim and quiet.

# Heartbeat as a separate subshell. Runs `set +e` and absorbs grep-no-match
# failures locally so a transient hiccup can't kill the parent. Killed
# explicitly after the wait loop returns.
(
    set +e
    while sleep "$RUN5_HB"; do
        elapsed=$(( $(date +%s) - RUN5_START ))
        active_days=()
        for i in "${!RUN5_PIDS[@]}"; do
            if kill -0 "${RUN5_PIDS[$i]}" 2>/dev/null; then
                active_days+=("${RUN5_DAYS[$i]}")
            fi
        done
        [[ ${#active_days[@]} -eq 0 ]] && exit 0
        echo "[m04_exit]   heartbeat: ${elapsed}s elapsed, active: ${active_days[*]}"
        for i in "${!RUN5_PIDS[@]}"; do
            pid="${RUN5_PIDS[$i]}"
            kill -0 "$pid" 2>/dev/null || continue
            d="${RUN5_DAYS[$i]}"
            l="${RUN5_LOGS[$i]}"
            last=$(grep -E "drive_beats:|cosim: driving" "$l" 2>/dev/null | tail -1 | sed 's/^.*INFO[[:space:]]*//' || true)
            echo "    $d: ${last:-<no progress yet>}"
        done
    done
) &
RUN5_HB_PID=$!

# Simple blocking wait — proven to work in the prior run. Order doesn't
# matter; `wait` returns each child's exit code.
RUN5_FAIL=0
for i in "${!RUN5_PIDS[@]}"; do
    pid="${RUN5_PIDS[$i]}"
    day="${RUN5_DAYS[$i]}"
    if wait "$pid"; then
        echo "[m04_exit]   $day: cocotb DONE"
    else
        rc=$?
        echo "[m04_exit]   $day: cocotb FAILED (rc=$rc); see ${RUN5_LOGS[$i]}" >&2
        RUN5_FAIL=1
    fi
done

# Stop the heartbeat.
kill "$RUN5_HB_PID" 2>/dev/null || true
wait "$RUN5_HB_PID" 2>/dev/null || true

[[ "$RUN5_FAIL" -eq 0 ]] || { echo "[m04_exit] step 5 cocotb fan-out failed" >&2; exit 1; }

# Now generate expected and diff per day (cheap; serial is fine).
for day in "${RUN5_DAYS[@]}"; do
    src="${REPO_ROOT}/data/pcaps/${day}.NASDAQ_ITCH50.gz"
    actual="${WORK}/${day}.10m.actual.bin"
    actual_slow="${WORK}/${day}.10m.actual.slow"
    expected="${WORK}/${day}.10m.expected.bin"
    expected_slow="${WORK}/${day}.10m.expected.slow"

    echo "[m04_exit]   $day: python parser (10M msgs)"
    python3 -m sw.replay.itch_slice "$src" "${WORK}/${day}.10m.itch" \
      -n 10000000 --no-compress
    # Set PYTHONPATH so _gen_expected.py can `from sw.replay import ...` —
    # `-m` works for scripts imported as modules, but _gen_expected.py is a
    # plain CLI and `python3 path/to/script.py` doesn't add REPO_ROOT to
    # sys.path. Mirrors run_slices.sh.
    PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}" \
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
