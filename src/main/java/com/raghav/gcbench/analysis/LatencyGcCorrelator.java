package com.raghav.gcbench.analysis;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

/**
 * Usage: LatencyGcCorrelator <latencyLogFile.jsonl> <jfrFile> [spikeThreshold]
 *
 * spikeThreshold, if given, is either:
 *   - a plain integer: an absolute threshold in nanoseconds, or
 *   - "xN" (e.g. "x3.0"): N times this run's own observed median inter-token
 *     latency.
 * Default is "x3.0". A relative threshold is the right default because an
 * absolute ms value doesn't transfer across token-rate assumptions (a
 * different model/provider, or a sped-up calibration run) -- "how many times
 * worse than this run's own normal" does.
 *
 * Reports latency percentiles and what fraction of latency spikes overlap a
 * GC pause window recorded in the same run's JFR file.
 *
 * Uses hand-rolled line parsing instead of a JSON library to keep the
 * project dependency-free -- safe only because LatencyEvent#toJsonLine
 * controls the exact output format read back here. This matters at scale:
 * a high-concurrency cell produces tens of millions of lines (e.g. 10,000
 * concurrent streams x 3 requests x 1000 tokens = 30M), and an earlier
 * regex-based version of this parser recompiled a Pattern on every single
 * field of every single line -- 60M+ Pattern.compile() calls for one cell,
 * which is slow enough to look like a hang. Plain substring scanning avoids
 * that entirely, and streaming the file (Files.lines) instead of loading it
 * all into memory first (Files.readAllLines) keeps peak memory bounded.
 */
public class LatencyGcCorrelator {

    public static void main(String[] args) throws IOException {
        Path latencyFile = Path.of(args[0]);
        Path jfrFile = Path.of(args[1]);
        String thresholdArg = args.length > 2 ? args[2] : "x3.0";

        ParsedLog log = parseLatencyLog(latencyFile);
        List<GcEvent> gcEvents = JfrGcExtractor.extract(jfrFile);

        long[] latencies = Arrays.copyOf(log.gaps, log.size);
        Arrays.sort(latencies);
        double p50 = percentile(latencies, 50);
        System.out.println("N tokens: " + latencies.length);
        System.out.printf("P50: %.2f ms%n", p50 / 1_000_000.0);
        System.out.printf("P99: %.2f ms%n", percentile(latencies, 99) / 1_000_000.0);
        System.out.printf("P99.9: %.2f ms%n", percentile(latencies, 99.9) / 1_000_000.0);

        long spikeThresholdNanos = thresholdArg.startsWith("x")
                ? (long) (p50 * Double.parseDouble(thresholdArg.substring(1)))
                : Long.parseLong(thresholdArg);
        System.out.printf("Spike threshold: %.2f ms (%s)%n", spikeThresholdNanos / 1_000_000.0, thresholdArg);

        // GC events are few (tens per run) even when there are tens of millions
        // of tokens, so a per-spike linear scan over gcEvents stays cheap --
        // the part that had to scale was the per-line parsing above, not this.
        long spikeCount = 0;
        long gcAttributableCount = 0;
        for (int i = 0; i < log.size; i++) {
            long gap = log.gaps[i];
            if (gap < spikeThresholdNanos) continue;
            spikeCount++;
            long tokenTimestamp = log.timestamps[i];
            long windowStart = tokenTimestamp - gap;
            boolean overlapsGc = gcEvents.stream().anyMatch(gc ->
                    gc.endEpochNanos() >= windowStart && gc.startEpochNanos() <= tokenTimestamp);
            if (overlapsGc) gcAttributableCount++;
        }

        System.out.println("Spikes (>" + (spikeThresholdNanos / 1_000_000) + "ms): " + spikeCount);
        System.out.println("GC-attributable spikes: " + gcAttributableCount
                + (spikeCount > 0 ? String.format(" (%.1f%%)", 100.0 * gcAttributableCount / spikeCount) : ""));
        System.out.println("Total GC events in recording: " + gcEvents.size());
    }

    private static final class ParsedLog {
        long[] timestamps;
        long[] gaps;
        int size;
    }

    private static ParsedLog parseLatencyLog(Path file) throws IOException {
        ParsedLog log = new ParsedLog();
        log.timestamps = new long[1 << 20];
        log.gaps = new long[1 << 20];
        try (BufferedReader reader = Files.newBufferedReader(file)) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.isEmpty()) continue;
                if (log.size == log.timestamps.length) {
                    log.timestamps = Arrays.copyOf(log.timestamps, log.timestamps.length * 2);
                    log.gaps = Arrays.copyOf(log.gaps, log.gaps.length * 2);
                }
                log.timestamps[log.size] = extractLong(line, "timestampEpochNanos");
                log.gaps[log.size] = extractLong(line, "interTokenLatencyNanos");
                log.size++;
            }
        }
        return log;
    }

    private static long extractLong(String line, String field) {
        String key = "\"" + field + "\":";
        int start = line.indexOf(key);
        if (start < 0) throw new IllegalArgumentException("field not found: " + field + " in " + line);
        start += key.length();
        int end = start;
        while (end < line.length() && (Character.isDigit(line.charAt(end)) || line.charAt(end) == '-')) {
            end++;
        }
        return Long.parseLong(line, start, end, 10);
    }

    private static double percentile(long[] sorted, double p) {
        if (sorted.length == 0) return 0;
        int index = (int) Math.ceil(p / 100.0 * sorted.length) - 1;
        return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
    }
}
