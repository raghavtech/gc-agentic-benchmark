package com.raghav.gcbench.analysis;

import java.time.Instant;

public record GcEvent(String name, Instant start, long durationNanos) {
    public long startEpochNanos() {
        return start.getEpochSecond() * 1_000_000_000L + start.getNano();
    }

    public long endEpochNanos() {
        return startEpochNanos() + durationNanos;
    }
}
