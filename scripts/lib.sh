#!/usr/bin/env bash
# Shared helpers for pilot.sh / run-experiment.sh.
#
# These exist because of a real failure mode hit during pilot calibration:
# a server process from an earlier (pre-fix) run was orphaned, kept squatting
# on the shared port, and every subsequent "new" server silently failed to
# bind while the load generator kept talking to the stale zombie the whole
# time -- producing plausible-looking but completely wrong results for every
# collector after the first. Unique ports per cell plus an explicit
# post-hoc collector check make that failure mode loud instead of silent.

# Blocks until the server on $1 actually answers, or fails loudly.
wait_for_server() {
  local port="$1" timeout="${2:-15}"
  local waited=0
  until curl -sf --max-time 1 "http://localhost:${port}/stream?tokens=1" -o /dev/null; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge $((timeout * 2)) ]; then
      echo "ERROR: server on port ${port} did not become ready within ${timeout}s" >&2
      return 1
    fi
  done
  return 0
}

# Compares the collector actually recorded in a JFR file against what this
# cell intended to test. Fails loudly on mismatch instead of trusting the
# label a script variable happened to say.
verify_collector() {
  local jfr_file="$1" expected="$2"
  local java_bin="${JAVA_BIN:-java}"
  local jfr_tool
  jfr_tool="$(dirname "$(command -v "$java_bin")")/jfr"

  local actual
  actual=$("$jfr_tool" print --events jdk.GCConfiguration "$jfr_file" 2>/dev/null \
    | grep -m1 "oldCollector" | sed 's/.*= "\(.*\)"/\1/')

  local match
  case "$expected" in
    g1) match="G1" ;;
    zgc) match="ZGC" ;;
    shenandoah) match="Shenandoah" ;;
    *) match="$expected" ;;
  esac

  if [[ "$actual" != *"$match"* ]]; then
    echo "ERROR: expected collector matching '${match}' but JFR shows oldCollector='${actual}' in ${jfr_file}" >&2
    return 1
  fi
  echo "collector check OK: ${expected} -> ${actual}"
  return 0
}

# Kills a PID and blocks until the port it held is actually free -- a plain
# `kill && sleep N` is a race under load; this polls the real signal (the
# port) instead of guessing a fixed delay.
kill_and_wait_port_free() {
  local pid="$1" port="$2" timeout="${3:-15}"
  kill "$pid" 2>/dev/null || true
  local waited=0
  while lsof -i ":${port}" -sTCP:LISTEN >/dev/null 2>&1; do
    sleep 0.5
    waited=$((waited + 1))
    if [ "$waited" -ge $((timeout * 2)) ]; then
      echo "WARNING: port ${port} still held after ${timeout}s, killing -9" >&2
      kill -9 "$pid" 2>/dev/null || true
      sleep 1
      break
    fi
  done
  wait "$pid" 2>/dev/null || true
}
