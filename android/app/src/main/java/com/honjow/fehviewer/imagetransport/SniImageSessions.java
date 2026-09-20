package com.honjow.fehviewer.imagetransport;

import java.io.IOException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import okhttp3.Call;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/** Bounded, cancellable HTTP streaming; independent of Flutter and app data. */
public final class SniImageSessions implements AutoCloseable {
    private static final int MAX_ACTIVE = 32;
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    private boolean closed;

    private static final class Session {
        final Request request;
        final int connectMs, readMs, totalMs;
        volatile OkHttpClient client;
        volatile Call call;
        volatile Response response;
        volatile boolean cancelled;
        Session(Request request, int connectMs, int readMs, int totalMs) {
            this.request = request;
            this.connectMs = connectMs;
            this.readMs = readMs;
            this.totalMs = totalMs;
        }
        void close() {
            cancelled = true;
            Call active = call;
            if (active != null) active.cancel();
            Response current = response;
            if (current != null) current.close();
            OkHttpClient owner = client;
            if (owner != null) {
                owner.connectionPool().evictAll();
                owner.dispatcher().executorService().shutdown();
            }
        }
    }

    public synchronized void prepare(String id, String url, Map<String, String> headers,
            int connectMs, int readMs, int totalMs) throws Exception {
        if (closed || sessions.size() >= MAX_ACTIVE || sessions.containsKey(id)) {
            throw new IOException("Compatibility capacity unavailable");
        }
        HttpUrl target = HttpUrl.get(url);
        if (!target.isHttps() || target.port() != 443
                || !target.host().endsWith(".hath.network")
                || !target.username().isEmpty() || !target.password().isEmpty()) {
            throw new IOException("Unsupported compatibility endpoint");
        }
        Request.Builder request = new Request.Builder().url(target).get();
        for (Map.Entry<String, String> entry : headers.entrySet()) {
            String key = entry.getKey().toLowerCase(Locale.ROOT);
            if (key.equals("accept") || key.equals("accept-language") || key.equals("user-agent")) {
                request.header(entry.getKey(), entry.getValue());
            }
        }
        // Reserve on the platform thread, but defer trust-store/SSLContext work
        // and all networking to start(), which runs on the worker executor.
        sessions.put(id, new Session(request.build(),
                Math.max(1, Math.min(connectMs, 10000)),
                Math.max(1, Math.min(readMs, 20000)),
                Math.max(1, Math.min(totalMs, 120000))));
    }

    public Map<String, Object> start(String id) throws IOException {
        Session session = require(id);
        try {
            session.client = NoSniClient.create(session.connectMs, session.readMs, session.totalMs);
            session.call = session.client.newCall(session.request);
        } catch (java.security.GeneralSecurityException error) {
            throw new IOException("System TLS context unavailable", error);
        }
        if (session.cancelled || sessions.get(id) != session) {
            session.close();
            throw new IOException("Compatibility request cancelled");
        }
        Response response = session.call.execute();
        session.response = response;
        if (sessions.get(id) != session || session.call.isCanceled()) {
            response.close();
            throw new IOException("Compatibility request cancelled");
        }
        Map<String, Object> result = new HashMap<>();
        result.put("status", response.code());
        result.put("headers", response.headers().toMultimap());
        return result;
    }

    public byte[] read(String id) throws IOException {
        Session session = require(id);
        Response response = session.response;
        if (response == null || response.body() == null) {
            throw new IOException("Compatibility response unavailable");
        }
        byte[] buffer = new byte[64 * 1024];
        int count = response.body().byteStream().read(buffer);
        return count == -1 ? null : Arrays.copyOf(buffer, count);
    }

    private Session require(String id) throws IOException {
        Session session = sessions.get(id);
        if (session == null) throw new IOException("Compatibility request cancelled");
        return session;
    }

    public void cancel(String id) {
        Session session = sessions.remove(id);
        if (session != null) session.close();
    }

    @Override public synchronized void close() {
        closed = true;
        for (String id : sessions.keySet()) cancel(id);
    }
}
