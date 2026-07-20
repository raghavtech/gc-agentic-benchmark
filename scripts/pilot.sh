#!/usr/bin/env bash
# Calibration pilot: small heap (to force GC activity to appear within a short
# run) x a few concurrency levels x all three collectors. Purpose is to find
# where interesting behavior shows up, NOT to produce publishable numbers --
# use scripts/run-experiment.sh with realistic heap sizing for the real study.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

COLLECTORS=("g1" "zgc" "shenandoah")
CONCURRENCY_LEVELS=(50 300 500)
REQUESTS_PER_THREAD=3
TOKENS_PER_REQUEST=1000
BASE_PORT=8200
RESULTS_DIR="data/pilot"
JAVA_BIN="${JAVA_BIN:-java}"

export HEAP="-Xms192m -Xmx192m"
export JAVA_BIN
# Calibration-only: compresses realistic per-token delays ~20x so enough
# tokens/garbage flow through in a short run to actually trigger GCs. The
# real study must NOT set this -- see SyntheticTokenSource's javadoc.
export EXTRA_JVM_ARGS="-Dgcbench.delayScale=0.05"

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

    echo "=== PILOT: ${collector} @ concurrency=${concurrency} (port ${port}) ===" >&2

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
    sleep 1  # let the JFR recording finish flushing to disk after process exit

    verify_collector "$JFR_FILE" "$collector"

    echo "--- analysis: ${collector} @ concurrency=${concurrency} ---"
    "$JAVA_BIN" -cp target/gc-agentic-benchmark.jar \
      com.raghav.gcbench.analysis.LatencyGcCorrelator \
      "$LATENCY_FILE" "$JFR_FILE" "x3.0" | tee "${RUN_DIR}/summary.txt"
  done
done

echo "Pilot complete. Results in ${RESULTS_DIR}/"
