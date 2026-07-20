#!/usr/bin/env bash
# Turns data/pilot2/<heap>/<collector>/c<concurrency>/{summary.txt,status.txt}
# into one CSV, including cells that failed (OOM, collector mismatch, etc)
# as their own rows -- a crash at a given heap/concurrency is data, not noise.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

RESULTS_DIR="data/pilot2"
OUT="${RESULTS_DIR}/aggregate.csv"

echo "heap,collector,concurrency,status,p50_ms,p99_ms,p999_ms,spike_threshold_ms,spike_count,gc_attributable_count,gc_attributable_pct,gc_event_count" > "$OUT"

for status_file in "$RESULTS_DIR"/*/*/*/status.txt; do
  dir=$(dirname "$status_file")
  concurrency=$(basename "$dir" | sed 's/^c//')
  collector=$(basename "$(dirname "$dir")")
  heap=$(basename "$(dirname "$(dirname "$dir")")")
  status=$(cat "$status_file")

  if [ "$status" != "OK" ]; then
    echo "${heap},${collector},${concurrency},${status},,,,,,,," >> "$OUT"
    continue
  fi

  summary="${dir}/summary.txt"
  p50=$(grep -oE "^P50: [0-9.]+" "$summary" | awk '{print $2}')
  p99=$(grep -oE "^P99: [0-9.]+" "$summary" | awk '{print $2}')
  p999=$(grep -oE "^P99\.9: [0-9.]+" "$summary" | awk '{print $2}')
  spike_thresh=$(grep -oE "^Spike threshold: [0-9.]+" "$summary" | awk '{print $3}')
  spike_count=$(grep -oE "^Spikes \(.*\): [0-9]+" "$summary" | awk '{print $NF}')
  gc_attrib=$(grep -oE "^GC-attributable spikes: [0-9]+" "$summary" | awk '{print $3}')
  gc_pct=$(grep -oE "\([0-9.]+%\)" "$summary" | head -1 | tr -d '(%)')
  gc_events=$(grep -oE "^Total GC events in recording: [0-9]+" "$summary" | awk '{print $NF}')

  echo "${heap},${collector},${concurrency},OK,${p50},${p99},${p999},${spike_thresh},${spike_count},${gc_attrib},${gc_pct},${gc_events}" >> "$OUT"
done

echo "Wrote ${OUT}"
column -s, -t "$OUT"
