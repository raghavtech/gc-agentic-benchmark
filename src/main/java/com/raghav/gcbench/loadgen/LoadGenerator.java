package com.raghav.gcbench.loadgen;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Opens N concurrent SSE streams against StreamingServer and records
 * per-token arrival latency. Run once per (collector, concurrency) cell
 * of the experiment matrix; each run writes its own latency log.
 *
 * Usage: LoadGenerator <baseUrl> <collectorLabel> <concurrency> <requestsPerThread> <tokensPerRequest> <outputFile>
 */
public class LoadGenerator {

    // A server that OOM-crashes mid-stream can leave a client blocked forever
    // in a plain read -- java.net.http's streaming InputStream body has no
    // built-in read timeout. Observed exactly this in the 2GB tier: a server
    // died from OOM, and the client sat blocked for over an hour with no
    // progress, stalling the entire remaining study behind it. This watchdog
    // force-closes the response stream if a whole request (normally ~20s)
    // takes more than READ_TIMEOUT_SECONDS, which reliably unblocks a pending
    // read with an IOException instead of hanging indefinitely.
    //
    // This covers only the body-reading phase, though -- it starts AFTER
    // client.send() already returned a response. A second, related hang
    // showed up immediately after this fix was first added: many concurrent
    // requests stuck in client.send() ITSELF, waiting for a response that
    // never arrives because the server died before ever replying. That phase
    // needs its own timeout, set directly on the HttpRequest below.
    private static final long READ_TIMEOUT_SECONDS = 60;
    private static final ScheduledExecutorService WATCHDOG = Executors.newScheduledThreadPool(2, r -> {
        Thread t = new Thread(r, "read-timeout-watchdog");
        t.setDaemon(true);
        return t;
    });

    public static void main(String[] args) throws Exception {
        String baseUrl = args[0];
        String collector = args[1];
        int concurrency = Integer.parseInt(args[2]);
        int requestsPerThread = Integer.parseInt(args[3]);
        int tokensPerRequest = Integer.parseInt(args[4]);
        Path outputFile = Path.of(args[5]);
        String runId = UUID.randomUUID().toString();

        try (LatencyLogger logger = new LatencyLogger(outputFile);
             ExecutorService pool = Executors.newVirtualThreadPerTaskExecutor()) {

            HttpClient client = HttpClient.newBuilder().executor(pool).build();
            CountDownLatch done = new CountDownLatch(concurrency);
            for (int i = 0; i < concurrency; i++) {
                pool.submit(() -> {
                    try {
                        for (int r = 0; r < requestsPerThread; r++) {
                            runOneRequest(client, baseUrl, collector, concurrency, tokensPerRequest, runId, logger);
                        }
                    } catch (Exception e) {
                        System.err.println("worker failed: " + e);
                    } finally {
                        done.countDown();
                    }
                });
            }
            done.await(30, TimeUnit.MINUTES);
        }
        System.out.println("Load generation complete: " + outputFile);
    }

    private static void runOneRequest(HttpClient client, String baseUrl, String collector,
                                       int concurrency, int tokensPerRequest, String runId,
                                       LatencyLogger logger) throws IOException, InterruptedException {
        String requestId = UUID.randomUUID().toString();
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(baseUrl + "/stream?tokens=" + tokensPerRequest))
                .timeout(Duration.ofSeconds(READ_TIMEOUT_SECONDS))
                .GET()
                .build();

        HttpResponse<InputStream> response =
                client.send(request, HttpResponse.BodyHandlers.ofInputStream());
        InputStream body = response.body();

        // See the class-level comment on READ_TIMEOUT_SECONDS/WATCHDOG: force-closes
        // `body` if this whole request runs long, unblocking a read that would
        // otherwise hang forever against a server that died mid-stream.
        ScheduledFuture<?> watchdog = WATCHDOG.schedule(() -> {
            try {
                body.close();
            } catch (IOException ignored) {
                // closing to force-unblock a stuck read; nothing to do with this
            }
        }, READ_TIMEOUT_SECONDS, TimeUnit.SECONDS);

        // Anchor a wall-clock Instant to a monotonic nanoTime reading so later
        // per-token timestamps can be expressed as epoch nanos -- needed to
        // correlate against JFR event timestamps, which are wall-clock, not
        // relative to this process's nanoTime origin.
        long anchorNanoTime = System.nanoTime();
        Instant anchorInstant = Instant.now();
        long lastTokenNanos = anchorNanoTime;
        int tokenIndex = 0;

        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(body, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!line.startsWith("data: ")) continue;
                long now = System.nanoTime();
                long gap = now - lastTokenNanos;
                lastTokenNanos = now;

                Instant eventInstant = anchorInstant.plusNanos(now - anchorNanoTime);
                long epochNanos = eventInstant.getEpochSecond() * 1_000_000_000L + eventInstant.getNano();

                logger.record(new LatencyEvent(runId, collector, concurrency, requestId,
                        tokenIndex, epochNanos, gap));
                tokenIndex++;
            }
        } finally {
            watchdog.cancel(false);
        }
    }
}
