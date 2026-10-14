package com.resonolabs.runtime.host;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One worker thread for loopback JSON calls to the runtime ({@code http://127.0.0.1:8765}, local
 * bearer token), with callbacks on the main thread that never arrive after {@link #close()}. The
 * voice-note and briefing clients share it; the runtime owns every call to the Mac.
 */
final class RuntimeJsonCall implements AutoCloseable {
    interface Callback {
        void onResult(JSONObject value);

        /**
         * {@code httpStatus} 0 = no answer: {@code runtime_unavailable} (never reached it) or
         * {@code runtime_timeout} (it was reached and the request sent, but no answer came in time);
         * otherwise {@code code} is the runtime's error code.
         */
        void onFailure(int httpStatus, String code);
    }

    private static final String BASE = "http://127.0.0.1:8765";
    private static final int MAX_BODY_BYTES = 256 * 1024;

    private final ExecutorService worker;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final AtomicBoolean closed = new AtomicBoolean();

    RuntimeJsonCall(String threadName) {
        worker = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, threadName);
            thread.setDaemon(true);
            return thread;
        });
    }

    void submit(Context context, String method, String path, JSONObject body, int readTimeoutMs, Callback callback) {
        if (closed.get()) return;
        Context application = context.getApplicationContext();
        try {
            worker.execute(() -> perform(application, method, path, body, readTimeoutMs, callback));
        } catch (RejectedExecutionException ignored) {
            // Closed concurrently; callbacks are suppressed after close.
        }
    }

    private void perform(Context context, String method, String path, JSONObject body, int readTimeoutMs,
                         Callback callback) {
        HttpURLConnection connection = null;
        boolean reached = false;
        try {
            String token = new RuntimeSecretStore(context).loadLocalApiToken();
            connection = (HttpURLConnection) new URL(BASE + path).openConnection();
            connection.setRequestMethod(method);
            connection.setConnectTimeout(1_500);
            connection.setReadTimeout(readTimeoutMs);
            connection.setRequestProperty("Authorization", "Bearer " + token);
            connection.setRequestProperty("Accept", "application/json");
            byte[] bytes = body == null ? null : body.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes != null) {
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setFixedLengthStreamingMode(bytes.length);
            }
            connection.connect(); // a connect timeout here means the runtime never got the request
            reached = true;
            if (bytes != null) {
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(bytes);
                }
            }
            int status = connection.getResponseCode();
            JSONObject value = parse(status >= 400 ? connection.getErrorStream() : connection.getInputStream());
            if (status >= 200 && status < 300) {
                if (!closed.get()) main.post(() -> { if (!closed.get()) callback.onResult(value); });
                return;
            }
            JSONObject error = value.optJSONObject("error");
            String code = error == null || error.isNull("code") ? "" : error.optString("code", "");
            fail(callback, status, code);
        } catch (ConnectException refused) {
            fail(callback, 0, "runtime_unavailable");
        } catch (SocketTimeoutException timeout) {
            fail(callback, 0, reached ? "runtime_timeout" : "runtime_unavailable");
        } catch (Exception error) {
            fail(callback, 0, "runtime_unavailable");
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static JSONObject parse(InputStream source) {
        if (source == null) return new JSONObject();
        try (InputStream input = source) {
            String text = new String(input.readNBytes(MAX_BODY_BYTES), StandardCharsets.UTF_8).trim();
            return text.isEmpty() ? new JSONObject() : new JSONObject(text);
        } catch (Exception ignored) {
            return new JSONObject();
        }
    }

    private void fail(Callback callback, int status, String code) {
        if (!closed.get()) main.post(() -> { if (!closed.get()) callback.onFailure(status, code); });
    }

    /** Lets a call already under way finish on the runtime; callbacks stop. */
    @Override public void close() {
        if (closed.compareAndSet(false, true)) worker.shutdown();
    }
}
