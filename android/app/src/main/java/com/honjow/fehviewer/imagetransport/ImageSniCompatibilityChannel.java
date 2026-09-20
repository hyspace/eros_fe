package com.honjow.fehviewer.imagetransport;

import android.os.Handler;
import android.os.Looper;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Small removable bridge. Never returns/logs a raw exception, URL or headers on failure. */
public final class ImageSniCompatibilityChannel implements AutoCloseable {
    private final MethodChannel channel;
    private final SniImageSessions sessions = new SniImageSessions();
    private final ExecutorService workers = Executors.newFixedThreadPool(4);
    private final Handler main = new Handler(Looper.getMainLooper());

    public ImageSniCompatibilityChannel(BinaryMessenger messenger) {
        channel = new MethodChannel(messenger, "fehviewer/image_sni_compat");
        channel.setMethodCallHandler(this::handle);
    }

    private void handle(MethodCall call, MethodChannel.Result result) {
        String id = call.argument("id");
        if (id == null || !id.matches("[0-9]+-[0-9]+")) {
            result.error("invalid_request", "Invalid compatibility request", null);
            return;
        }
        if (call.method.equals("cancel")) {
            sessions.cancel(id);
            result.success(null);
            return;
        }
        if (!call.method.equals("start") && !call.method.equals("read")) {
            result.notImplemented();
            return;
        }
        try {
            if (call.method.equals("start")) {
                Map<String, String> headers = call.argument("headers");
                sessions.prepare(id, call.argument("url"),
                        headers == null ? Collections.emptyMap() : headers,
                        number(call, "connect_ms"), number(call, "read_ms"), number(call, "total_ms"));
            }
            workers.execute(() -> {
                try {
                    Object value = call.method.equals("start") ? sessions.start(id) : sessions.read(id);
                    main.post(() -> result.success(value));
                } catch (Exception error) {
                    sessions.cancel(id);
                    main.post(() -> result.error("transport_failed",
                            "Strict image compatibility transport failed", null));
                }
            });
        } catch (Exception error) {
            sessions.cancel(id);
            result.error("transport_unavailable", "Image compatibility transport unavailable", null);
        }
    }

    private static int number(MethodCall call, String key) {
        Number value = call.argument(key);
        return value == null ? 0 : value.intValue();
    }

    @Override public void close() {
        channel.setMethodCallHandler(null);
        sessions.close();
        workers.shutdownNow();
    }
}
