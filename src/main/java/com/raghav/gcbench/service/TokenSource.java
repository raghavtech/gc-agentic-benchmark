package com.raghav.gcbench.service;

import java.util.List;

public interface TokenSource {
    List<TimedToken> generate(int tokenCount);
}
