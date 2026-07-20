package com.raghav.gcbench.service;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.LockSupport;

/**
 * Minimal SSE token-streaming server used as the GC-benchmark subject.
 * Deliberately dependency-free (no Spring/Netty) so that observed GC
 * behavior is attributable to the JVM/collector under test and to the
 * allocation pattern modeled here, not to framework overhead. Real Spring
 * AI / LangChain4j deployments add further allocation on top of this
 * baseline -- treat these results as a lower bound on GC pressure, not a
 * full substitute for testing your actual stack.
 */
public class StreamingServer {

    public static void main(String[] args) throws IOException {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 8080;
        int defaultTokenCount = args.length > 1 ? Integer.parseInt(args[1]) : 200;

        TokenSource tokenSource = new SyntheticTokenSource();

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/stream", exchange -> handleStream(exchange, tokenSource, defaultTokenCount));
        server.start();

        System.out.println("StreamingServer listening on port " + port);
    }

    private static void handleStream(HttpExchange exchange, TokenSource tokenSource, int defaultTokenCount) {
        try {
            int tokenCount = parseTokenCount(exchange, defaultTokenCount);
            exchange.getResponseHeaders().add("Content-Type", "text/event-stream");
            exchange.getResponseHeaders().add("Cache-Control", "no-cache");
            exchange.sendResponseHeaders(200, 0); // 0 => chunked transfer

            List<TimedToken> tokens = tokenSource.generate(tokenCount);
            ConversationContext context = new ConversationContext();

            try (OutputStream out = exchange.getResponseBody()) {
                for (TimedToken t : tokens) {
                    LockSupport.parkNanos(t.delayBeforeEmitNanos());
                    context.onToken(t.text());
                    String frame = "data: " + t.text() + "\n\n";
                    out.write(frame.getBytes(StandardCharsets.UTF_8));
                    out.flush();
                }
            }
        } catch (Exception e) {
            exchange.close();
        }
    }

    private static int parseTokenCount(HttpExchange exchange, int defaultTokenCount) {
        String query = exchange.getRequestURI().getRawQuery();
        if (query == null) return defaultTokenCount;
        for (String pair : query.split("&")) {
            String[] kv = pair.split("=", 2);
            if (kv.length == 2 && kv[0].equals("tokens")) {
                try {
                    return Integer.parseInt(kv[1]);
                } catch (NumberFormatException ignored) {
                    // fall through to default
                }
            }
        }
        return defaultTokenCount;
    }
}
