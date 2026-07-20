#!/usr/bin/env bash
# Second calibration pass: does the concurrency sweep reach far enough to
# show clear collector divergence at REALISTIC heap sizes, not just the
# artificially tiny 192MB used to force GC activity quickly in pilot.sh?
#
# Same delayScale calibration trick as pilot.sh (compressed timing, NOT
# representative of the real study) -- purpose here is purely to find the
# right concurrency range before committing to the slow, unscaled real run.
#
# A single cell OOM-ing (small heap + high concurrency) is expected and is
# itself informative data -- a "collector cannot sustain this load at this
# heap size" data point, not a bug. So each cell is fully isolated: a crash,
# collector mismatch, or analysis failure is recorded in that cell's
# status.txt and the sweep continues, rather than aborting the whole run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

HEAP_SIZES=("512m" "1g" "2g")
COLLECTORS=("g1" "zgc" "shenandoah")
CONCURRENCY_LEVELS=(100 500 1000 2500 5000)
REQUESTS_PER_THREAD=3
TOKENS_PER_REQUEST=1000
BASE_PORT=8500
RESULTS_DIR="data/pilot2"
JAVA_BIN="${JAVA_BIN:-java}"
export JAVA_BIN
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
for heap in "${HEAP_SIZES[@]}"; do
  export HEAP="-Xms${heap} -Xmx${heap}"
  for collector in "${COLLECTORS[@]}"; do
    for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
      port=$((BASE_PORT + port_offset))
      port_offset=$((port_offset + 1))
      RUN_DIR="${RESULTS_DIR}/${heap}/${collector}/c${concurrency}"
      mkdir -p "$RUN_DIR"

      echo "=== heap=${heap} collector=${collector} concurrency=${concurrency} (port ${port}) ===" >&2
      if run_cell "$collector" "$concurrency" "$port" "$RUN_DIR"; then
        echo "  -> $(grep 'GC-attributable' "${RUN_DIR}/summary.txt")" >&2
      else
        echo "  -> CELL FAILED: $(cat "${RUN_DIR}/status.txt" 2>/dev/null || echo unknown)" >&2
      fi
      # Belt-and-suspenders: make sure nothing from this cell survives into the next.
      pkill -f "StreamingServer $port\$" 2>/dev/null || true
    done
  done
done

echo "Heap sweep pilot complete. Results in ${RESULTS_DIR}/"
