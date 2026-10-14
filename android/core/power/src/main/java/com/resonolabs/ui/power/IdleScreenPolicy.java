package com.resonolabs.ui.power;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Window;
import android.view.WindowManager;

import java.util.function.BooleanSupplier;

/**
 * The single owner of HOME's {@code FLAG_KEEP_SCREEN_ON}: the screen goes off after 10 minutes
 * with nothing going on (Settings &gt; Display, or never).
 *
 * <p>HOME's window disables user activity ({@link DisplayPolicy}), so its touches and the wheel
 * never reach PowerManager's own timeout; only this flag kept the screen on. Interactions arrive
 * from the activity (touch, keys, the wheel, side-button gestures, resume, screen on); the busy
 * probe is asked again whenever something says it changed and every 30 s while busy. On release
 * the flag is cleared and PowerManager sleeps the panel through its normal timeout path (its
 * last user activity is long past). The next interaction, resume or screen-on arms it again.
 *
 * <p>Debug builds: {@code adb shell setprop debug.sam.idle_ms 60000} shortens the idle time
 * (read on start and resume). Main thread only.
 */
public final class IdleScreenPolicy implements AutoCloseable {
    private static final String TAG = "SamIdleScreen";
    public static final String DEBUG_PROPERTY = "debug.sam.idle_ms";

    private final Window window;
    private final Context context;
    private final BooleanSupplier busyProbe;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final IdleScreenClock clock;
    private final Runnable check = this::evaluate;
    private final Runnable settingChanged = this::onSettingChanged;
    private long debugIdleMs;
    private boolean held;
    private boolean started;
    private long scheduledAt = Long.MAX_VALUE;

    public IdleScreenPolicy(Context context, Window window, BooleanSupplier busyProbe) {
        this.context = context.getApplicationContext() != null ? context.getApplicationContext() : context;
        this.window = window;
        this.busyProbe = busyProbe;
        clock = new IdleScreenClock(SystemClock.elapsedRealtime());
    }

    public void start() {
        if (started) return;
        started = true;
        IdleScreenSetting.addListener(settingChanged);
        debugIdleMs = readDebugIdleMs();
        hold();
        evaluate();
    }

    /** A touch, the wheel, a key or a side-button gesture: cheap, called for every event. */
    public void onInteraction() {
        clock.interaction(SystemClock.elapsedRealtime());
        if (!held && started) {
            hold();
            evaluate();
        }
    }

    /** The activity resumed or the screen came on: counts as an interaction. */
    public void onResume() {
        debugIdleMs = readDebugIdleMs();
        clock.interaction(SystemClock.elapsedRealtime());
        if (!started) return;
        if (!held) hold();
        evaluate();
    }

    /** Something busy started or ended (a voice session, a note, a timer): decide again now. */
    public void onBusyChanged() {
        if (started) evaluate();
    }

    /** True while the flag is set (debug state). */
    public boolean holding() {
        return held;
    }

    /** Milliseconds of idle before the screen goes off, or {@link IdleScreenClock#NEVER}. */
    public long idleMs() {
        long configured = IdleScreenSetting.idleMs(context);
        if (configured <= 0L) return IdleScreenClock.NEVER;
        return debugIdleMs > 0L ? debugIdleMs : configured;
    }

    private void onSettingChanged() {
        handler.post(() -> {
            clock.interaction(SystemClock.elapsedRealtime());
            if (!held) hold();
            evaluate();
        });
    }

    private void evaluate() {
        if (!started) return;
        long now = SystemClock.elapsedRealtime();
        boolean busy;
        try {
            busy = busyProbe.getAsBoolean();
        } catch (RuntimeException error) {
            busy = true; // never let a broken probe turn the screen off under someone
        }
        clock.busy(busy, now);
        if (busy && !held) hold();
        IdleScreenClock.Decision decision = clock.decide(now, idleMs());
        if (decision.keep) {
            if (!held) hold();
            schedule(decision.nextCheckAt, now);
        } else if (held) {
            release();
        }
    }

    private void schedule(long at, long now) {
        if (at == Long.MAX_VALUE) {
            handler.removeCallbacks(check);
            scheduledAt = Long.MAX_VALUE;
            return;
        }
        if (at == scheduledAt) return;
        handler.removeCallbacks(check);
        scheduledAt = at;
        handler.postDelayed(check, Math.max(50L, at - now));
    }

    private void hold() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (!held) Log.i(TAG, "screen kept on (idle off after " + describe(idleMs()) + ")");
        held = true;
    }

    private void release() {
        handler.removeCallbacks(check);
        scheduledAt = Long.MAX_VALUE;
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        held = false;
        Log.i(TAG, "idle " + describe(idleMs()) + ": screen may sleep");
    }

    private static String describe(long ms) {
        if (ms <= 0L) return "never";
        return ms % 60_000L == 0L ? (ms / 60_000L) + " min" : (ms / 1000L) + " s";
    }

    /** {@code debug.sam.idle_ms} on debuggable builds (at least 10 s), else 0. */
    private long readDebugIdleMs() {
        if ((context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return 0L;
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Object value = properties.getMethod("get", String.class, String.class).invoke(null, DEBUG_PROPERTY, "");
            String text = String.valueOf(value).trim();
            if (text.isEmpty()) return 0L;
            long ms = Long.parseLong(text);
            if (ms > 0L) Log.i(TAG, DEBUG_PROPERTY + "=" + ms);
            return ms <= 0L ? 0L : Math.max(10_000L, ms);
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            return 0L;
        }
    }

    @Override public void close() {
        started = false;
        IdleScreenSetting.removeListener(settingChanged);
        handler.removeCallbacks(check);
    }
}
