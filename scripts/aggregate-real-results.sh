#!/usr/bin/env bash
# Aggregates data/results/<heap>/<collector>/c<concurrency>/rep<N>/summary.txt
# across repetitions into one CSV: one row per (heap, collector, concurrency),
# with mean/min/max for the metrics that matter, plus how many of the 3 reps
# actually succeeded (anything other than 3/3 is worth a second look).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RESULTS_DIR="${1:-data/results}"
OUT="${RESULTS_DIR}/aggregate.csv"

echo "heap,collector,concurrency,reps_ok,p50_ms_mean,p99_ms_mean,p999_ms_mean,gc_attrib_pct_mean,gc_attrib_pct_min,gc_attrib_pct_max,gc_events_mean" > "$OUT"

for cdir in "$RESULTS_DIR"/*/*/c*/; do
  [ -d "$cdir" ] || continue
  concurrency=$(basename "$cdir" | sed 's/^c//')
  collector=$(basename "$(dirname "$cdir")")
  heap=$(basename "$(dirname "$(dirname "$cdir")")")

  p50s=() p99s=() p999s=() gc_pcts=() gc_events=()
  reps_ok=0
  for repdir in "$cdir"rep*/; do
    [ -f "${repdir}status.txt" ] || continue
    status=$(cat "${repdir}status.txt")
    [ "$status" = "OK" ] || continue
    summary="${repdir}summary.txt"
    [ -f "$summary" ] || continue
    reps_ok=$((reps_ok + 1))
    p50s+=("$(grep -oE '^P50: [0-9.]+' "$summary" | awk '{print $2}')")
    p99s+=("$(grep -oE '^P99: [0-9.]+' "$summary" | awk '{print $2}')")
    p999s+=("$(grep -oE '^P99\.9: [0-9.]+' "$summary" | awk '{print $2}')")
    gc_pcts+=("$(grep -oE '\([0-9.]+%\)' "$summary" | head -1 | tr -d '(%)')")
    gc_events+=("$(grep -oE '^Total GC events in recording: [0-9]+' "$summary" | awk '{print $NF}')")
  done

  if [ "$reps_ok" -eq 0 ]; then
    echo "${heap},${collector},${concurrency},0,,,,,,," >> "$OUT"
    continue
  fi

  mean() { local sum=0; for v in "$@"; do sum=$(echo "$sum + $v" | bc -l); done; echo "scale=3; $sum / $#" | bc -l; }
  minv() { printf '%s\n' "$@" | sort -n | head -1; }
  maxv() { printf '%s\n' "$@" | sort -n | tail -1; }

  p50_mean=$(mean "${p50s[@]}")
  p99_mean=$(mean "${p99s[@]}")
  p999_mean=$(mean "${p999s[@]}")
  gc_pct_mean=$(mean "${gc_pcts[@]}")
  gc_pct_min=$(minv "${gc_pcts[@]}")
  gc_pct_max=$(maxv "${gc_pcts[@]}")
  gc_events_mean=$(mean "${gc_events[@]}")

  echo "${heap},${collector},${concurrency},${reps_ok}/3,${p50_mean},${p99_mean},${p999_mean},${gc_pct_mean},${gc_pct_min},${gc_pct_max},${gc_events_mean}" >> "$OUT"
done

echo "Wrote ${OUT}"
column -s, -t "$OUT"
