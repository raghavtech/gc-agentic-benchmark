package com.raghav.gcbench.service;

import java.util.ArrayList;
import java.util.List;

/**
 * Simulates the allocation/retention pattern of an agent-orchestration layer
 * holding growing conversation state across a streamed response: a per-token
 * append plus periodic snapshotting into a retained history list. This is
 * what turns "streaming tokens" into actual GC pressure worth measuring --
 * a request that only ever holds one token at a time would never exercise
 * the retention behavior real agent orchestration code exhibits.
 */
public class ConversationContext {

    private final StringBuilder buffer = new StringBuilder();
    private final List<String> history = new ArrayList<>();
    private int tokensSinceSnapshot = 0;

    public void onToken(String token) {
        buffer.append(token).append(' ');
        tokensSinceSnapshot++;
        if (tokensSinceSnapshot >= 20) {
            history.add(buffer.toString());
            tokensSinceSnapshot = 0;
        }
    }

    public int retainedHistoryEntries() {
        return history.size();
    }
}
