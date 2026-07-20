package com.raghav.gcbench.service;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Generates a token stream with a delay distribution shaped like observed LLM
 * streaming behavior: a longer time-to-first-token followed by shorter,
 * log-normally distributed inter-token gaps. This is a plausible shape, not a
 * calibration against any specific provider's real traffic -- before treating
 * the absolute numbers in the study as representative, capture real inter-token
 * latency samples from your actual provider/model and refit these parameters.
 *
 * The -Dgcbench.delayScale system property (default 1.0) uniformly scales
 * every delay. It exists ONLY to let a calibration pilot push a realistic
 * volume of tokens/garbage through in a short wall-clock run -- the real
 * study must run with delayScale=1.0 (unset), since the whole point is
 * measuring behavior under realistic inter-token timing.
 */
public class SyntheticTokenSource implements TokenSource {

    private static final long TTFT_MEAN_NANOS = 200_000_000L;   // 200ms
    private static final long TTFT_STDDEV_NANOS = 60_000_000L;  // 60ms
    private static final double ITL_LOG_MEAN = Math.log(20_000_000L); // ~20ms median
    private static final double ITL_LOG_STDDEV = 0.5;

    private static final double DELAY_SCALE =
            Double.parseDouble(System.getProperty("gcbench.delayScale", "1.0"));

    @Override
    public List<TimedToken> generate(int tokenCount) {
        var rnd = ThreadLocalRandom.current();
        List<TimedToken> tokens = new ArrayList<>(tokenCount);
        for (int i = 0; i < tokenCount; i++) {
            long delay = (i == 0)
                    ? clampPositive((long) (rnd.nextGaussian() * TTFT_STDDEV_NANOS + TTFT_MEAN_NANOS))
                    : (long) Math.exp(rnd.nextGaussian() * ITL_LOG_STDDEV + ITL_LOG_MEAN);
            tokens.add(new TimedToken("tok" + i, clampPositive((long) (delay * DELAY_SCALE))));
        }
        return tokens;
    }

    private static long clampPositive(long v) {
        return Math.max(v, 1_000_000L); // floor at 1ms
    }
}
