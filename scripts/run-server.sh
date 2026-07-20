#!/usr/bin/env bash
# Usage: run-server.sh <collector: g1|zgc|shenandoah> <port> <jfrOutputFile>
set -euo pipefail

COLLECTOR="$1"
PORT="$2"
JFR_OUT="$3"
HEAP="${HEAP:--Xms2g -Xmx2g}"
JAVA_BIN="${JAVA_BIN:-java}"
EXTRA_JVM_ARGS="${EXTRA_JVM_ARGS:-}"

case "$COLLECTOR" in
  g1)
    GC_FLAGS="-XX:+UseG1GC"
    ;;
  zgc)
    # On JDK 21/22, generational mode is opt-in via -XX:+ZGenerational.
    # On JDK 23+, generational is the only/default mode and this flag no
    # longer exists (confirmed against a local JDK 26 build) -- drop it there.
    GC_FLAGS="-XX:+UseZGC -XX:+ZGenerational"
    ;;
  shenandoah)
    GC_FLAGS="-XX:+UseShenandoahGC"
    ;;
  *)
    echo "unknown collector: $COLLECTOR (expected g1|zgc|shenandoah)" >&2
    exit 1
    ;;
esac

# exec replaces this shell with the JVM process, so a `kill` on the PID
# captured by a caller's `$!` signals the JVM directly -- without this, the
# JVM runs as an orphaned child once this wrapper script exits/is killed,
# and never receives the SIGTERM that triggers its JFR shutdown-hook flush.
exec "$JAVA_BIN" $HEAP $GC_FLAGS $EXTRA_JVM_ARGS \
  -XX:StartFlightRecording=filename="$JFR_OUT",settings=profile,disk=true \
  -cp target/gc-agentic-benchmark.jar \
  com.raghav.gcbench.service.StreamingServer "$PORT"
