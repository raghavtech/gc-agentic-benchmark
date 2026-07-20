#!/usr/bin/env bash
# Orchestrates the full experiment matrix: collectors x concurrency levels.
# Run from the project root: ./scripts/run-experiment.sh
#
# NOTE: CONCURRENCY_LEVELS below is a placeholder until the pilot's findings
# are folded in -- see data/pilot/ANALYSIS.md (or the study plan doc) for the
# sweep actually chosen and why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

COLLECTORS=("g1" "zgc" "shenandoah")
CONCURRENCY_LEVELS=(50 200 500 1000 2000)
REQUESTS_PER_THREAD=10
TOKENS_PER_REQUEST=200
BASE_PORT=8300
RESULTS_DIR="data/results"
JAVA_BIN="${JAVA_BIN:-java}"
export JAVA_BIN

mkdir -p "$RESULTS_DIR"

port_offset=0
for collector in "${COLLECTORS[@]}"; do
  for concurrency in "${CONCURRENCY_LEVELS[@]}"; do
    port=$((BASE_PORT + port_offset))
    port_offset=$((port_offset + 1))
    base_url="http://localhost:${port}"

    RUN_DIR="${RESULTS_DIR}/${collector}/c${concurrency}"
    mkdir -p "$RUN_DIR"
    JFR_FILE="${RUN_DIR}/recording.jfr"
    LATENCY_FILE="${RUN_DIR}/latency.jsonl"

    echo "=== ${collector} @ concurrency=${concurrency} (port ${port}) ==="

    ./scripts/run-server.sh "$collector" "$port" "$JFR_FILE" > "${RUN_DIR}/server.log" 2>&1 &
    SERVER_PID=$!

    if ! wait_for_server "$port" 15; then
      cat "${RUN_DIR}/server.log" >&2
      kill -9 "$SERVER_PID" 2>/dev/null || true
      exit 1
    fi

    "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
      com.raghav.gcbench.loadgen.LoadGenerator \
      "$base_url" "$collector" "$concurrency" "$REQUESTS_PER_THREAD" "$TOKENS_PER_REQUEST" "$LATENCY_FILE"

    kill_and_wait_port_free "$SERVER_PID" "$port" 15
    sleep 1

    verify_collector "$JFR_FILE" "$collector"

    echo "--- analysis: ${collector} @ concurrency=${concurrency} ---"
    "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
      com.raghav.gcbench.analysis.LatencyGcCorrelator \
      "$LATENCY_FILE" "$JFR_FILE" | tee "${RUN_DIR}/summary.txt"
  done
done

echo "All runs complete. Results in ${RESULTS_DIR}/"
