package com.resonolabs.ui.power;

/**
 * When HOME may let the screen go off (pure, unit-tested). The screen stays on while something is
 * busy (a voice session, a voice note or dictation, a running or ringing timer, the camera, an open
 * sheet) and for {@code idleMs} after the later of the last interaction and the moment the last
 * busy thing ended; then it may sleep. {@code idleMs <= 0} means never.
 *
 * <p>Times are one monotonic clock (elapsed realtime) in milliseconds.
 */
public final class IdleScreenClock {
    public static final long DEFAULT_IDLE_MS = 10L * 60L * 1000L;
    public static final long NEVER = -1L;
    /** While busy, look again this often: a busy source may end without telling. */
    public static final long BUSY_CHECK_MS = 30_000L;

    /** Keep the screen on until at least {@link #nextCheckAt}, or release it now. */
    public static final class Decision {
        public final boolean keep;
        /** When to decide again ({@code Long.MAX_VALUE}: only when something changes). */
        public final long nextCheckAt;

        Decision(boolean keep, long nextCheckAt) {
            this.keep = keep;
            this.nextCheckAt = nextCheckAt;
        }
    }

    private long lastInteractionAt;
    private long busyEndedAt = Long.MIN_VALUE;
    private boolean busy;

    public IdleScreenClock(long now) {
        lastInteractionAt = now;
    }

    /** A touch, the wheel, a key, a side-button gesture, a resume or the screen coming on. */
    public void interaction(long now) {
        if (now > lastInteractionAt) lastInteractionAt = now;
    }

    /** The busy probe's latest answer; going idle starts the idle time again. */
    public void busy(boolean value, long now) {
        if (busy && !value) busyEndedAt = now;
        busy = value;
    }

    public boolean busy() {
        return busy;
    }

    public long lastInteractionAt() {
        return lastInteractionAt;
    }

    public Decision decide(long now, long idleMs) {
        return decide(now, lastInteractionAt, busy, busyEndedAt, idleMs);
    }

    /** {@code idleSince = max(lastInteraction, busyEndedAt)}; release once {@code idleMs} has passed. */
    public static Decision decide(long now, long lastInteractionAt, boolean busy, long busyEndedAt, long idleMs) {
        if (idleMs <= 0L) return new Decision(true, Long.MAX_VALUE);
        if (busy) return new Decision(true, now + BUSY_CHECK_MS);
        long idleSince = Math.max(lastInteractionAt, busyEndedAt);
        long releaseAt = idleSince + idleMs;
        if (now >= releaseAt) return new Decision(false, Long.MAX_VALUE);
        return new Decision(true, releaseAt);
    }
}
