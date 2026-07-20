#!/usr/bin/env bash
# The real, publication-grade study run: unscaled (realistic) timing, no
# delayScale calibration shortcut. Concurrency levels per heap tier and the
# 3x repetition count were chosen from pilot calibration (data/pilot2/) to
# avoid wasting runs on guaranteed-OOM cells while still characterizing each
# heap tier's real capacity boundary, and to average out run-to-run noise
# rather than report single-sample point estimates.
#
# Usage: run-real-study.sh <512m|1g|2g|4g>
# Run once per heap tier (not all in one call) so a several-hour study
# has natural checkpoints instead of being one all-or-nothing background run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

HEAP_TIER="${1:?Usage: run-real-study.sh <512m|1g|2g|4g>}"
REQUESTS_PER_THREAD=3
TOKENS_PER_REQUEST=1000
REPEATS=3
BASE_PORT_512M=8600
BASE_PORT_1G=8700
BASE_PORT_2G=8800
BASE_PORT_4G=8900
RESULTS_DIR="data/results"
JAVA_BIN="${JAVA_BIN:-java}"
export JAVA_BIN
unset EXTRA_JVM_ARGS || true   # real study: no timing compression -- realistic per-token delays

concurrency_levels_for_heap() {
  case "$1" in
    512m) echo "100 500 1000" ;;                        # 2500/5000 reliably OOM per pilot2
    1g)   echo "100 500 1000 2500" ;;                    # 5000 reliably OOMs per pilot2
    2g)   echo "100 500 1000 2500 5000 7500 10000" ;;    # survived full pilot2 range; pushed further
    4g)   echo "@@4G_LEVELS_PENDING_CALIBRATION@@" ;;    # fill in from data/pilot4g/ before running
    *)    echo "unknown heap tier: $1" >&2; exit 1 ;;
  esac
}

base_port_for_heap() {
  case "$1" in
    512m) echo "$BASE_PORT_512M" ;;
    1g)   echo "$BASE_PORT_1G" ;;
    2g)   echo "$BASE_PORT_2G" ;;
    4g)   echo "$BASE_PORT_4G" ;;
  esac
}

COLLECTORS=("g1" "zgc" "shenandoah")

run_cell() {
  local collector="$1" concurrency="$2" port="$3" run_dir="$4"
  local jfr_file="${run_dir}/recording.jfr"
  local latency_file="${run_dir}/latency.jsonl"
  local base_url="http://localhost:${port}"

  ./scripts/run-server.sh "$collector" "$port" "$jfr_file" > "${run_dir}/server.log" 2>&1 &
  local server_pid=$!

  if ! wait_for_server "$port" 20; then
    echo "SERVER_FAILED_TO_START" > "${run_dir}/status.txt"
    kill -9 "$server_pid" 2>/dev/null || true
    return 1
  fi

  "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
    com.raghav.gcbench.loadgen.LoadGenerator \
    "$base_url" "$collector" "$concurrency" "$REQUESTS_PER_THREAD" "$TOKENS_PER_REQUEST" "$latency_file" \
    > "${run_dir}/loadgen.log" 2>&1
  local loadgen_status=$?

  kill_and_wait_port_free "$server_pid" "$port" 20
  sleep 1

  if grep -q "OutOfMemoryError" "${run_dir}/server.log" 2>/dev/null; then
    echo "OOM" > "${run_dir}/status.txt"
    return 2
  fi
  if [ "$loadgen_status" -ne 0 ]; then
    echo "LOADGEN_FAILED" > "${run_dir}/status.txt"
    return 5
  fi

  if ! verify_collector "$jfr_file" "$collector" > "${run_dir}/collector_check.txt" 2>&1; then
    echo "COLLECTOR_MISMATCH" > "${run_dir}/status.txt"
    return 3
  fi

  if ! "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
      com.raghav.gcbench.analysis.LatencyGcCorrelator \
      "$latency_file" "$jfr_file" "x3.0" > "${run_dir}/summary.txt" 2>&1; then
    echo "ANALYSIS_FAILED" > "${run_dir}/status.txt"
    return 4
  fi

  echo "OK" > "${run_dir}/status.txt"
  return 0
}

export HEAP="-Xms${HEAP_TIER} -Xmx${HEAP_TIER}"
base_port=$(base_port_for_heap "$HEAP_TIER")
levels=$(concurrency_levels_for_heap "$HEAP_TIER")

port_offset=0
cell_count=0
for collector in "${COLLECTORS[@]}"; do
  for concurrency in $levels; do
    for rep in $(seq 1 "$REPEATS"); do
      port=$((base_port + port_offset))
      port_offset=$((port_offset + 1))
      RUN_DIR="${RESULTS_DIR}/${HEAP_TIER}/${collector}/c${concurrency}/rep${rep}"
      mkdir -p "$RUN_DIR"
      cell_count=$((cell_count + 1))

      # Resume support: a status.txt means this cell already ran to completion
      # (whatever the outcome) in an earlier invocation -- skip it rather than
      # redo work. Needed because a stuck cell (e.g. the client-hang bug fixed
      # alongside this) can require killing and restarting the whole script;
      # without this, resuming meant redoing every already-completed cell too.
      if [ -f "${RUN_DIR}/status.txt" ]; then
        echo "=== [${HEAP_TIER} #${cell_count}] collector=${collector} concurrency=${concurrency} rep=${rep} -- SKIPPING (already: $(cat "${RUN_DIR}/status.txt")) ===" >&2
        continue
      fi

      echo "=== [${HEAP_TIER} #${cell_count}] collector=${collector} concurrency=${concurrency} rep=${rep} (port ${port}) ===" >&2
      if run_cell "$collector" "$concurrency" "$port" "$RUN_DIR"; then
        echo "  -> $(grep 'GC-attributable' "${RUN_DIR}/summary.txt")" >&2
      else
        echo "  -> CELL FAILED: $(cat "${RUN_DIR}/status.txt" 2>/dev/null || echo unknown)" >&2
      fi
      pkill -f "StreamingServer $port\$" 2>/dev/null || true
    done
  done
done

echo "Real study (heap=${HEAP_TIER}) complete. ${cell_count} cells run. Results in ${RESULTS_DIR}/${HEAP_TIER}/"
