package com.raghav.gcbench.loadgen;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * Single-writer-thread logger: all recording virtual threads enqueue events
 * and return immediately, so file I/O contention never perturbs the latency
 * measurements it's trying to record.
 *
 * The queue is bounded deliberately. An unbounded queue was tried first and
 * caused a real stall during calibration: at very high concurrency under
 * compressed (delayScale) timing, thousands of virtual threads can produce
 * events far faster than one writer thread can drain them, so an unbounded
 * queue just grows -- tens of millions of queued objects causing severe GC
 * pressure in the load generator itself, which looked like a hang (0% CPU,
 * barely any forward progress) rather than a clean crash. A bounded queue
 * with a blocking put() makes producers throttle naturally instead.
 */
public class LatencyLogger implements AutoCloseable {

    private static final int QUEUE_CAPACITY = 200_000;

    private static final LatencyEvent POISON_PILL =
            new LatencyEvent("__stop__", "", 0, "", 0, 0, 0);

    private final BlockingQueue<LatencyEvent> queue = new LinkedBlockingQueue<>(QUEUE_CAPACITY);
    private final Thread writerThread;

    public LatencyLogger(Path outputFile) throws IOException {
        BufferedWriter writer = Files.newBufferedWriter(outputFile);
        writerThread = new Thread(() -> drain(writer), "latency-logger");
        writerThread.start();
    }

    public void record(LatencyEvent event) {
        try {
            queue.put(event);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new RuntimeException(e);
        }
    }

    private void drain(BufferedWriter writer) {
        try {
            while (true) {
                LatencyEvent event = queue.take();
                if (event == POISON_PILL) break;
                writer.write(event.toJsonLine());
                writer.newLine();
            }
            writer.flush();
            writer.close();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    @Override
    public void close() throws InterruptedException {
        queue.put(POISON_PILL);
        writerThread.join();
    }
}
