#!/usr/bin/env bash
# Calibration pass for the newly-added 4GB heap tier, mirroring what
# pilot-heap-sweep.sh already did for 512MB/1GB/2GB. Skips the low
# concurrency levels (100/500) since prior tiers showed minimal GC activity
# there regardless of heap size -- not informative to re-verify. Extends
# further than the 2GB pilot range since 4GB has more headroom and we don't
# yet know where (or if) it breaks.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

COLLECTORS=("g1" "zgc" "shenandoah")
CONCURRENCY_LEVELS=(1000 2500 5000 10000 15000 20000)
REQUESTS_PER_THREAD=3
TOKENS_PER_REQUEST=1000
BASE_PORT=8950
RESULTS_DIR="data/pilot4g"
JAVA_BIN="${JAVA_BIN:-java}"
export JAVA_BIN
export HEAP="-Xms4g -Xmx4g"
export EXTRA_JVM_ARGS="-Dgcbench.delayScale=0.05"

mkdir -p "$RESULTS_DIR"

run_cell() {
  local collector="$1" concurrency="$2" port="$3" run_dir="$4"
  local jfr_file="${run_dir}/recording.jfr"
  local latency_file="${run_dir}/latency.jsonl"
  local base_url="http://localhost:${port}"

  ./scripts/run-server.sh "$collector" "$port" "$jfr_file" > "${run_dir}/server.log" 2>&1 &
  local server_pid=$!

  if ! wait_for_server "$port" 15; then
    echo "SERVER_FAILED_TO_START" > "${run_dir}/status.txt"
    kill -9 "$server_pid" 2>/dev/null || true
    return 1
  fi

  "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
    com.raghav.gcbench.loadgen.LoadGenerator \
    "$base_url" "$collector" "$concurrency" "$REQUESTS_PER_THREAD" "$TOKENS_PER_REQUEST" "$latency_file" \
    > "${run_dir}/loadgen.log" 2>&1
  local loadgen_status=$?

  kill_and_wait_port_free "$server_pid" "$port" 15
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

port_offset=0
for collector in "${COLLECTORS[@]}"; do
  for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
    port=$((BASE_PORT + port_offset))
    port_offset=$((port_offset + 1))
    RUN_DIR="${RESULTS_DIR}/${collector}/c${concurrency}"
    mkdir -p "$RUN_DIR"

    echo "=== 4g collector=${collector} concurrency=${concurrency} (port ${port}) ===" >&2
    if run_cell "$collector" "$concurrency" "$port" "$RUN_DIR"; then
      echo "  -> $(grep 'GC-attributable' "${RUN_DIR}/summary.txt")" >&2
    else
      echo "  -> CELL FAILED: $(cat "${RUN_DIR}/status.txt" 2>/dev/null || echo unknown)" >&2
    fi
    pkill -f "StreamingServer $port\$" 2>/dev/null || true
  done
done

echo "4g calibration complete. Results in ${RESULTS_DIR}/"
