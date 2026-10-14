package com.resonolabs.ui.power;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Settings &gt; Side button: which side-button gesture records a voice note (default triple press).
 * The double press always talks. The app turns the choice into the framework's live
 * {@code Settings.Global} power-button keys (see the app's SideButtonGesture); listeners hear a
 * change at once. Device-protected storage: HOME is direct-boot aware.
 */
public final class SideButtonSetting {
    public enum VoiceNote {
        /** Three quick presses (each within 0.3 s of the last). */
        TRIPLE("Triple press"),
        /** Hold the button for half a second; the power menu moves to a 3.5 s hold. */
        HOLD("Hold"),
        BOTH("Both");

        public final String label;

        VoiceNote(String label) {
            this.label = label;
        }

        public boolean triple() {
            return this != HOLD;
        }

        public boolean hold() {
            return this != TRIPLE;
        }
    }

    /** Whether the triple press really works on this boot (the framework overlay decides). */
    public enum TripleState { UNKNOWN, READY, NEEDS_RESTART, UNAVAILABLE }

    private static final String PREFS = "sam_side_button";
    private static final String KEY = "voice_note";
    private static final CopyOnWriteArrayList<Runnable> LISTENERS = new CopyOnWriteArrayList<>();
    private static volatile TripleState tripleState = TripleState.UNKNOWN;
    private static SharedPreferences prefs;

    private SideButtonSetting() {}

    public static VoiceNote voiceNote(Context context) {
        String value = prefs(context).getString(KEY, VoiceNote.TRIPLE.name());
        try {
            return VoiceNote.valueOf(value);
        } catch (IllegalArgumentException | NullPointerException unknown) {
            return VoiceNote.TRIPLE;
        }
    }

    public static void setVoiceNote(Context context, VoiceNote choice) {
        prefs(context).edit().putString(KEY, choice.name()).apply();
        for (Runnable listener : LISTENERS) listener.run();
    }

    public static TripleState tripleState() {
        return tripleState;
    }

    /** Reported by the app's framework policy check, for the Settings page. */
    public static void reportTripleState(TripleState state) {
        tripleState = state == null ? TripleState.UNKNOWN : state;
    }

    public static void addListener(Runnable listener) {
        LISTENERS.addIfAbsent(listener);
    }

    public static void removeListener(Runnable listener) {
        LISTENERS.remove(listener);
    }

    private static synchronized SharedPreferences prefs(Context context) {
        if (prefs == null) {
            Context app = context.getApplicationContext() != null ? context.getApplicationContext() : context;
            prefs = app.createDeviceProtectedStorageContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        }
        return prefs;
    }
}
