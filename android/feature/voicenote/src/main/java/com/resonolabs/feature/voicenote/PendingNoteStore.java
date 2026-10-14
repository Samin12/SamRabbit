package com.resonolabs.feature.voicenote;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;

/**
 * Voice notes the runtime could not take yet (it was restarting, or it didn't answer in time), in
 * device-protected preferences so they survive the app and a reboot. Written synchronously: a note
 * is on disk before the R1 says "Saved". Main thread only. Transcripts are never logged.
 */
final class PendingNoteStore {
    /** Far more than a runtime restart can pile up; past it a note is refused (visibly), never dropped. */
    static final int MAX_NOTES = 100;
    private static final String FILE = "sam_voice_note_outbox";
    private static final String PREFIX = "note.";

    private final SharedPreferences prefs;

    PendingNoteStore(Context context) {
        Context storage = context.createDeviceProtectedStorageContext();
        prefs = storage.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    /** True once the note is on disk (false when full or the write failed). */
    boolean put(PendingNote note) {
        String key = PREFIX + note.id;
        if (!prefs.contains(key) && prefs.getAll().size() >= MAX_NOTES) return false;
        return prefs.edit().putString(key, note.toJson()).commit();
    }

    void remove(String id) {
        if (id == null || id.isEmpty()) return;
        prefs.edit().remove(PREFIX + id).commit();
    }

    boolean isEmpty() {
        return prefs.getAll().isEmpty();
    }

    /** Oldest first. */
    List<PendingNote> all() {
        List<PendingNote> out = new ArrayList<>();
        for (Map.Entry<String, ?> entry : prefs.getAll().entrySet()) {
            if (!entry.getKey().startsWith(PREFIX) || !(entry.getValue() instanceof String value)) continue;
            PendingNote note = PendingNote.fromJson(value);
            if (note != null) out.add(note);
        }
        out.sort(Comparator.comparingLong(note -> note.savedAtMs));
        return out;
    }
}
