# gc-agentic-benchmark

Experiment harness for the study "Does Garbage Collection Disqualify Java from
Agentic AI's Hot Path?" Measures P50/P99/P99.9 token-streaming latency under
G1, (generational) ZGC, and Shenandoah, and correlates latency spikes against
actual GC pause events recorded via JFR.

Zero external dependencies -- everything (`java.net.http`, `com.sun.net.httpserver`,
`jdk.jfr.consumer`) ships with the JDK. That's deliberate: it keeps the
allocation/GC behavior attributable to the collector under test, not to a
framework's own overhead.

## Components

- `service.StreamingServer` -- the subject under test. Streams synthetic
  tokens over SSE, with a `ConversationContext` that accumulates retained
  history the way a real agent-orchestration layer would, so the workload
  actually generates the allocation pressure GC tuning is meant to address.
- `loadgen.LoadGenerator` -- opens N concurrent SSE streams (one virtual
  thread each) and logs per-token arrival latency to a JSONL file.
- `analysis.JfrGcExtractor` / `LatencyGcCorrelator` -- reads a JFR recording,
  extracts GC pause events, computes latency percentiles, and reports what
  fraction of latency spikes overlap a GC pause window.

## Prerequisites

- JDK 21+ (virtual threads). Verified against JDK 21.0.9 in this repo.
- For the collector comparison specifically:
  - **G1**: available in every JDK build.
  - **ZGC**: generational mode is opt-in via `-XX:+ZGenerational` on JDK
    21-22; it's the only mode on JDK 23+ and that flag no longer exists there
    (confirmed against a local JDK 26 build -- `run-server.sh` will need
    editing if you run on 23+).
  - **Shenandoah**: not included in every vendor's JDK build (present in
    Homebrew's OpenJDK build and Eclipse Temurin; absent from Oracle JDK).
    Check with `java -XX:+UnlockExperimentalVMOptions -XX:+PrintFlagsFinal -version | grep UseShenandoahGC`
    before assuming it's available.
- Run all three collectors on the **same JDK build and the same hardware**
  in the actual study -- mixing JDK versions across collectors would
  confound the comparison.

## Build

```
mvn package
```

Produces `target/gc-agentic-benchmark.jar`.

## Quick smoke test

```
java -Xms512m -Xmx512m -XX:+UseG1GC \
  -XX:StartFlightRecording=filename=/tmp/rec.jfr,settings=profile,disk=true \
  -cp target/gc-agentic-benchmark.jar com.raghav.gcbench.service.StreamingServer 8099 &

java -cp target/gc-agentic-benchmark.jar com.raghav.gcbench.loadgen.LoadGenerator \
  http://localhost:8099 g1 20 3 50 /tmp/latency.jsonl

java -cp target/gc-agentic-benchmark.jar com.raghav.gcbench.analysis.LatencyGcCorrelator \
  /tmp/latency.jsonl /tmp/rec.jfr
```

## Full experiment matrix

```
./scripts/run-experiment.sh
```

Runs every (collector x concurrency) cell defined in the script, writing
`data/results/<collector>/c<concurrency>/{recording.jfr,latency.jsonl,summary.txt}`.
Edit `COLLECTORS`, `CONCURRENCY_LEVELS`, `REQUESTS_PER_THREAD`, and
`TOKENS_PER_REQUEST` at the top of `scripts/run-experiment.sh` to match the
study's actual design once that's finalized.

## What's still a placeholder, not a finished study

1. **Token timing is synthetic**, calibrated to a plausible shape (`SyntheticTokenSource`),
   not fit to real provider traces. Before treating absolute numbers as
   representative, capture real inter-token latency samples from an actual
   LLM API or local model and refit the distribution parameters.
2. **Spike threshold and concurrency levels** in `run-experiment.sh` are
   starting guesses -- tune them after an initial pilot run shows where
   the interesting behavior actually shows up.
3. **JFR event field names** in `JfrGcExtractor` were not verified against
   a live recording's exact schema in this pass -- the smoke test confirmed
   `jdk.GarbageCollection` events are found and read without exception, but
   run `jfr print --events jdk.GarbageCollection <file>` on your target JDK
   before trusting the analysis on a real multi-hour run.
4. **No real LLM backend yet.** Swapping in a real API (OpenAI/Anthropic
   streaming, or a local Ollama model) as a second `TokenSource`
   implementation is the natural next step to validate the synthetic
   results generalize -- see `TokenSource` interface.
5. **No plotting.** `summary.txt` per run is plain text; aggregating across
   runs into latency-vs-concurrency charts per collector is manual/TBD.
