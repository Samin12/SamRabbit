package com.resonolabs.feature.voicenote;

import org.json.JSONObject;

/**
 * One voice note on its way to the runtime ({@code POST /v1/capture}): its capture id (made when
 * recording started, the idempotency key end to end) and everything the runtime needs to store it.
 * Kept in the app ({@link PendingNoteStore}) only while the runtime can't be reached, so a runtime
 * restart never loses the words; resent with the same id.
 */
final class PendingNote {
    final String id;
    final String text;
    final String capturedAt;
    final long durationMs;
    final String trigger;
    final long savedAtMs;

    PendingNote(String id, String text, String capturedAt, long durationMs, String trigger, long savedAtMs) {
        this.id = id == null ? "" : id;
        this.text = text == null ? "" : text;
        this.capturedAt = capturedAt == null ? "" : capturedAt;
        this.durationMs = Math.max(0L, durationMs);
        this.trigger = trigger == null || trigger.isBlank() ? "tap" : trigger;
        this.savedAtMs = savedAtMs;
    }

    String toJson() {
        try {
            return new JSONObject().put("id", id).put("text", text).put("capturedAt", capturedAt)
                    .put("durationMs", durationMs).put("trigger", trigger).put("savedAt", savedAtMs).toString();
        } catch (Exception impossible) {
            return "{}"; // strings and numbers always encode
        }
    }

    /** Null for anything that is not a whole note (an empty id or no words). */
    static PendingNote fromJson(String value) {
        if (value == null || value.isBlank()) return null;
        try {
            JSONObject json = new JSONObject(value);
            PendingNote note = new PendingNote(json.optString("id", ""), json.optString("text", ""),
                    json.optString("capturedAt", ""), json.optLong("durationMs", 0L), json.optString("trigger", ""),
                    json.optLong("savedAt", 0L));
            return note.id.isEmpty() || note.text.isBlank() || note.capturedAt.isEmpty() ? null : note;
        } catch (Exception invalid) {
            return null;
        }
    }
}
