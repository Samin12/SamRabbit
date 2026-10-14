package com.resonolabs.ui.power;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Settings &gt; Display "Screen off: after 10 min / Never" (default 10 min). Read by
 * {@link IdleScreenPolicy}; listeners hear a change at once. Device-protected storage: HOME is
 * direct-boot aware.
 */
public final class IdleScreenSetting {
    private static final String PREFS = "sam_display";
    private static final String KEY = "idle_off_ms";
    private static final CopyOnWriteArrayList<Runnable> LISTENERS = new CopyOnWriteArrayList<>();
    private static SharedPreferences prefs;

    private IdleScreenSetting() {}

    /** Milliseconds of idle before the screen goes off, or {@link IdleScreenClock#NEVER}. */
    public static long idleMs(Context context) {
        long value = prefs(context).getLong(KEY, IdleScreenClock.DEFAULT_IDLE_MS);
        return value <= 0L ? IdleScreenClock.NEVER : value;
    }

    public static boolean never(Context context) {
        return idleMs(context) <= 0L;
    }

    public static void setNever(Context context, boolean never) {
        prefs(context).edit().putLong(KEY, never ? IdleScreenClock.NEVER : IdleScreenClock.DEFAULT_IDLE_MS).apply();
        for (Runnable listener : LISTENERS) listener.run();
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
