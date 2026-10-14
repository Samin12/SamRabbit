package com.resonolabs.runtime.host;

import android.content.Context;

import org.json.JSONObject;

/**
 * Device-only client for the runtime's morning-briefing routes: {@code GET /v1/briefing} (the R1's
 * cache, never a wait on the Mac), {@code POST /v1/briefing/refresh} and
 * {@code POST /v1/briefing/items/<id>/act {action}}. Drafts are Gmail drafts made on the Mac;
 * nothing is ever sent. Callbacks arrive on the main thread and never after {@link #close()}.
 */
public final class BriefingClient implements AutoCloseable {
    public interface Callback {
        void onResult(JSONObject value);

        /** {@code httpStatus} 0 = runtime not reachable; {@code code} is the runtime's error code. */
        void onFailure(int httpStatus, String code);
    }

    private static final int READ_TIMEOUT_MS = 4_000;
    /** A draft reply is written on the Mac before Gmail stores it. */
    private static final int ACT_TIMEOUT_MS = 50_000;

    private final RuntimeJsonCall calls = new RuntimeJsonCall("sam-briefing");

    public void load(Context context, Callback callback) {
        calls.submit(context, "GET", "/v1/briefing", null, READ_TIMEOUT_MS, wrap(callback));
    }

    public void refresh(Context context, Callback callback) {
        calls.submit(context, "POST", "/v1/briefing/refresh", new JSONObject(), READ_TIMEOUT_MS, wrap(callback));
    }

    /** {@code action}: draft_reply | make_task | block_time | remind | done | dismiss | open. */
    public void act(Context context, String itemId, String action, Callback callback) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", action);
        } catch (Exception ignored) {
            // A String value cannot fail to encode.
        }
        calls.submit(context, "POST", "/v1/briefing/items/" + android.net.Uri.encode(itemId) + "/act", body,
                ACT_TIMEOUT_MS, wrap(callback));
    }

    private static RuntimeJsonCall.Callback wrap(Callback callback) {
        return new RuntimeJsonCall.Callback() {
            @Override public void onResult(JSONObject value) { callback.onResult(value); }
            @Override public void onFailure(int httpStatus, String code) { callback.onFailure(httpStatus, code); }
        };
    }

    @Override public void close() {
        calls.close();
    }
}
