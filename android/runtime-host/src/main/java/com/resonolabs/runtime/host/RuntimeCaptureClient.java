package com.resonolabs.runtime.host;

import android.content.Context;

import org.json.JSONObject;

/**
 * Device-only client for the runtime's voice-note route ({@code POST /v1/capture}). The runtime
 * stores the note before it tries the Mac bridge and answers {@code {captureId, state, say, kind?,
 * outcome?}} with {@code state} done | sent | queued | failed, so an answer always means the note is
 * safe somewhere. Callbacks arrive on the main thread and never after {@link #close()}.
 */
public final class RuntimeCaptureClient implements AutoCloseable {
    public interface Callback {
        void onResult(JSONObject value);

        /** {@code httpStatus} 0 = runtime not reachable; {@code code} is the runtime's error code. */
        void onFailure(int httpStatus, String code);
    }

    /** The runtime tries the Mac (~8 s) and waits for the outcome (~8 s) before it answers. */
    private static final int SUBMIT_TIMEOUT_MS = 30_000;

    private final RuntimeJsonCall calls = new RuntimeJsonCall("sam-capture");

    /**
     * {@code captureId}: a UUID made when recording started (the idempotency key); {@code capturedAt}:
     * ISO time with its offset; {@code trigger}: triple_press | hold | tap.
     */
    public void submit(Context context, String captureId, String text, String capturedAt, long durationMs,
                       String trigger, Callback callback) {
        JSONObject body = new JSONObject();
        try {
            body.put("captureId", captureId).put("text", text == null ? "" : text).put("capturedAt", capturedAt)
                    .put("durationMs", Math.max(0L, durationMs)).put("trigger", trigger == null ? "tap" : trigger)
                    .put("source", "r1").put("lang", "en");
        } catch (Exception ignored) {
            // Strings and numbers cannot fail to encode.
        }
        calls.submit(context, "POST", "/v1/capture", body, SUBMIT_TIMEOUT_MS, new RuntimeJsonCall.Callback() {
            @Override public void onResult(JSONObject value) { callback.onResult(value); }
            @Override public void onFailure(int httpStatus, String code) { callback.onFailure(httpStatus, code); }
        });
    }

    @Override public void close() {
        calls.close();
    }
}
