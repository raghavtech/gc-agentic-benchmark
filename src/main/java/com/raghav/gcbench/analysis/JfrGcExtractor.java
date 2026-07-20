package com.raghav.gcbench.analysis;

import jdk.jfr.consumer.RecordedEvent;
import jdk.jfr.consumer.RecordingFile;

import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Extracts GC pause events from a JFR recording. Uses the jdk.GarbageCollection
 * event, which is emitted by every HotSpot collector (G1, ZGC, Shenandoah),
 * making cross-collector comparison possible from a single event type instead
 * of collector-specific events.
 *
 * Verify the field names below against your exact JDK build before trusting
 * them -- run `jfr print --events jdk.GarbageCollection <file>` on a sample
 * recording first. JFR event schemas have shifted across OpenJDK releases,
 * and this was not compiled/run against a live JFR file in this pass.
 */
public class JfrGcExtractor {

    public static List<GcEvent> extract(Path jfrFile) throws IOException {
        List<GcEvent> events = new ArrayList<>();
        try (RecordingFile rf = new RecordingFile(jfrFile)) {
            while (rf.hasMoreEvents()) {
                RecordedEvent e = rf.readEvent();
                if (!e.getEventType().getName().equals("jdk.GarbageCollection")) continue;

                String name = e.hasField("name") ? e.getString("name") : "unknown";
                long durationNanos = e.getDuration().toNanos();
                events.add(new GcEvent(name, e.getStartTime(), durationNanos));
            }
        }
        return events;
    }
}
