package com.raghav.gcbench.loadgen;

public record LatencyEvent(
        String runId,
        String collector,
        int concurrency,
        String requestId,
        int tokenIndex,
        long timestampEpochNanos,
        long interTokenLatencyNanos
) {
    public String toJsonLine() {
        return "{\"runId\":\"" + runId + "\",\"collector\":\"" + collector + "\",\"concurrency\":" + concurrency
                + ",\"requestId\":\"" + requestId + "\",\"tokenIndex\":" + tokenIndex
                + ",\"timestampEpochNanos\":" + timestampEpochNanos
                + ",\"interTokenLatencyNanos\":" + interTokenLatencyNanos + "}";
    }
}
