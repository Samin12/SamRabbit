package com.resonolabs.feature.voicenote;

/**
 * One voice note from start to its result (pure; times in elapsed-realtime milliseconds).
 *
 * <pre>
 * IDLE ─start→ STARTING ─live→ LISTENING ─finish/silence/limit→ FINISHING ─words→ SENDING ─answer→ SENT | QUEUED | FAILED
 *                 │                 │                               └─no words→ NOTHING_HEARD
 *                 └──────── cancel (BACK) ──────────────────────────────────→ CANCELLED
 * </pre>
 *
 * A result stays on screen for a moment ({@link #RESULT_MS}), then the machine is idle again.
 * Nothing here ever speaks: the note is one shot, no back and forth.
 */
public final class VoiceNoteMachine {
    public enum Phase { IDLE, STARTING, LISTENING, FINISHING, SENDING, SENT, QUEUED, NOTHING_HEARD, FAILED, CANCELLED }

    /** How long "Sent ✓ — Added to your journal" stays up. */
    public static final long RESULT_MS = 2_200L;
    /** Results that need a second look (saved for later, failures) stay a little longer. */
    public static final long LONG_RESULT_MS = 3_200L;
    public static final long CANCELLED_MS = 700L;
    /** The countdown appears for the last stretch of the 180 s cap. */
    public static final long COUNTDOWN_MS = 15_000L;

    private Phase phase = Phase.IDLE;
    private long startedAt;
    private long liveAt;
    private long endedAt;
    private long resultUntil;
    private String line = "";

    public Phase phase() {
        return phase;
    }

    /** STARTING or LISTENING: a gesture, a tap or the wheel finishes the note. */
    public boolean recording() {
        return phase == Phase.STARTING || phase == Phase.LISTENING;
    }

    /** From start until the runtime answered: the screen stays on and the overlay is up. */
    public boolean active() {
        return recording() || phase == Phase.FINISHING || phase == Phase.SENDING;
    }

    /** Active, or a result still on screen. */
    public boolean showing(long now) {
        return active() || (phase != Phase.IDLE && now < resultUntil);
    }

    /** The result or failure line under the title ("Added to your journal"). */
    public String line() {
        return line;
    }

    public boolean start(long now) {
        if (active()) return false;
        phase = Phase.STARTING;
        startedAt = now;
        liveAt = 0L;
        endedAt = 0L;
        resultUntil = 0L;
        line = "";
        return true;
    }

    public void onLive(long now) {
        if (phase == Phase.STARTING) {
            phase = Phase.LISTENING;
            liveAt = now;
        }
    }

    /** The user finished it (tap, wheel press, any side-button gesture, the screen going off). */
    public boolean finish(long now) {
        if (!recording()) return false;
        phase = Phase.FINISHING;
        endedAt = now;
        return true;
    }

    /** Dictation ended on its own (silence, the cap) or after {@link #finish}: send the words, if any. */
    public boolean onWords(String words, long now) {
        if (phase != Phase.STARTING && phase != Phase.LISTENING && phase != Phase.FINISHING) return false;
        if (endedAt == 0L) endedAt = now;
        if (words == null || words.isBlank()) {
            show(Phase.NOTHING_HEARD, "Nothing was sent.", now, LONG_RESULT_MS);
            return false;
        }
        phase = Phase.SENDING;
        return true;
    }

    /** Dictation could not start or broke (no microphone, no OpenAI, no network). */
    public void onFailure(String message, long now) {
        if (!active()) return;
        show(Phase.FAILED, message == null || message.isBlank() ? "Couldn't record. Try again." : message, now,
                LONG_RESULT_MS);
    }

    /** The runtime's answer: {@code state} done | sent | queued | failed and its short line. */
    public void onSent(String state, String say, long now) {
        if (phase != Phase.SENDING) return;
        String text = say == null ? "" : say.trim();
        switch (state == null ? "" : state) {
            case "done", "sent" -> show(Phase.SENT, text.isEmpty() ? "Sent to your Mac." : text, now, RESULT_MS);
            case "queued" -> show(Phase.QUEUED, text.isEmpty() ? "On the R1 until your Mac is back." : text,
                    now, LONG_RESULT_MS);
            default -> show(Phase.FAILED, text.isEmpty() ? "Couldn't save that note." : text, now, LONG_RESULT_MS);
        }
    }

    /** BACK: drop it. Nothing is sent. */
    public boolean cancel(long now) {
        if (!active() || phase == Phase.SENDING) return false;
        show(Phase.CANCELLED, "Nothing was sent.", now, CANCELLED_MS);
        return true;
    }

    /** Hides a result early (a tap on it). */
    public void dismiss(long now) {
        if (!active() && phase != Phase.IDLE) resultUntil = now;
    }

    /** Back to IDLE once a result has been shown long enough. True when it changed. */
    public boolean tick(long now) {
        if (active() || phase == Phase.IDLE || now < resultUntil) return false;
        phase = Phase.IDLE;
        return true;
    }

    /** Milliseconds recorded so far (or in total once finished). */
    public long durationMs(long now) {
        if (liveAt == 0L) return 0L;
        return Math.max(0L, (endedAt == 0L ? now : endedAt) - liveAt);
    }

    /** Left before the cap while listening; {@code Long.MAX_VALUE} otherwise. */
    public long remainingMs(long now, long maxListenMs) {
        if (phase != Phase.LISTENING) return Long.MAX_VALUE;
        return Math.max(0L, maxListenMs - (now - liveAt));
    }

    /** True while the "12 s left" countdown should show. */
    public boolean countdown(long now, long maxListenMs) {
        return remainingMs(now, maxListenMs) <= COUNTDOWN_MS;
    }

    /** Title for the overlay (the second line is {@link #line()} or the live words). */
    public String title() {
        return switch (phase) {
            case STARTING -> "Starting…";
            case LISTENING -> "Recording…";
            case FINISHING -> "Finishing…";
            case SENDING -> "Sending…";
            case SENT -> "Sent ✓";
            case QUEUED -> "Saved ✓";
            case NOTHING_HEARD -> "I didn't catch anything";
            case FAILED -> "Not sent";
            case CANCELLED -> "Cancelled";
            case IDLE -> "";
        };
    }

    /** Small hint line for the input that applies right now. */
    public String hint() {
        return switch (phase) {
            case STARTING, LISTENING -> "Tap or press to send · Back to cancel";
            case FINISHING, SENDING -> "";
            default -> "Tap to close";
        };
    }

    public long startedAt() {
        return startedAt;
    }

    /**
     * Debug screenshots only (DEBUG_NOTE): puts the machine in {@code target} without a microphone,
     * shown for a minute or until {@link #dismiss}; null goes back to IDLE.
     */
    public void debugPreview(Phase target, String text, long now) {
        if (target == null || target == Phase.IDLE) {
            phase = Phase.IDLE;
            resultUntil = 0L;
            return;
        }
        phase = target;
        startedAt = now - 7_400L;
        liveAt = now - 7_000L;
        endedAt = target == Phase.LISTENING || target == Phase.STARTING ? 0L : now;
        line = text == null ? "" : text;
        resultUntil = now + 60_000L;
    }

    private void show(Phase result, String text, long now, long durationMs) {
        phase = result;
        line = text;
        resultUntil = now + durationMs;
    }
}
