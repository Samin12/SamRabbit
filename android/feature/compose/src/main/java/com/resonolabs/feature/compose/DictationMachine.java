package com.resonolabs.feature.compose;

/**
 * When a dictation starts, listens, winds down and ends. Pure Java: the session feeds it server
 * VAD events and a clock ({@code now} in elapsed-realtime milliseconds) and performs the
 * returned {@link Action}.
 *
 * <pre>
 * IDLE ─start→ CONNECTING ─live→ LISTENING ─stop/limits→ FINISHING ─words settled→ DONE
 *                  └──stop/timeout/failure──────────────────────────────────────→ DONE
 * </pre>
 *
 * Stopping mutes the microphone; server VAD then hears the silence and commits the words in
 * flight with their own item id. If VAD still thinks speech is going on after
 * {@link #COMMIT_AFTER_MS}, the session commits the buffer itself. FINISHING ends once every
 * heard item is transcribed, or after {@link #FINISH_TIMEOUT_MS}.
 */
public final class DictationMachine {
    public enum Phase { IDLE, CONNECTING, LISTENING, FINISHING, DONE }

    /** Why listening ended. */
    public enum Stop { NONE, USER, MAX_DURATION, SILENCE, NO_SPEECH, VOICE_SESSION, PAUSED, CANCELLED, FAILED }

    public enum Action {
        NONE,
        /** Mute the microphone; transcripts in flight still arrive. */
        MUTE,
        /** Send {@code input_audio_buffer.commit} for speech VAD has not closed yet. */
        COMMIT,
        /** Release the peer and the microphone; the dictation is over. */
        CLOSE
    }

    public static final long MAX_LISTEN_MS = 60_000L;
    public static final long NO_SPEECH_MS = 8_000L;
    /** Quiet time after VAD's speech_stopped (itself ~0.7 s after the last word). */
    public static final long TRAILING_SILENCE_MS = 4_000L;
    public static final long CONNECT_TIMEOUT_MS = 15_000L;
    public static final long COMMIT_AFTER_MS = 1_500L;
    public static final long FINISH_TIMEOUT_MS = 5_000L;

    /**
     * How long one dictation may listen, wait for the first words, wait in silence after the last
     * ones and wait to connect. {@link #DEFAULT} is the text fields' (ComposeSheet); voice notes use
     * longer listening and a shorter trailing silence.
     */
    public static final class Limits {
        public static final Limits DEFAULT =
                new Limits(MAX_LISTEN_MS, NO_SPEECH_MS, TRAILING_SILENCE_MS, CONNECT_TIMEOUT_MS);

        public final long maxListenMs;
        public final long noSpeechMs;
        public final long trailingSilenceMs;
        public final long connectTimeoutMs;

        public Limits(long maxListenMs, long noSpeechMs, long trailingSilenceMs, long connectTimeoutMs) {
            this.maxListenMs = maxListenMs;
            this.noSpeechMs = noSpeechMs;
            this.trailingSilenceMs = trailingSilenceMs;
            this.connectTimeoutMs = connectTimeoutMs;
        }
    }

    private final Limits limits;

    private Phase phase = Phase.IDLE;
    private Stop stop = Stop.NONE;
    private long startedAt;
    private long liveAt;
    private long finishingAt;
    private long lastSpeechStoppedAt;
    private boolean speechActive;
    private boolean heardSpeech;
    private boolean commitSent;

    public DictationMachine() {
        this(Limits.DEFAULT);
    }

    public DictationMachine(Limits limits) {
        this.limits = limits == null ? Limits.DEFAULT : limits;
    }

    public Limits limits() {
        return limits;
    }

    public Phase phase() {
        return phase;
    }

    public Stop stopReason() {
        return stop;
    }

    /** True from start until DONE. */
    public boolean active() {
        return phase == Phase.CONNECTING || phase == Phase.LISTENING || phase == Phase.FINISHING;
    }

    public boolean speechActive() {
        return speechActive;
    }

    /** Milliseconds of listening left before the max duration, for a countdown. */
    public long remainingMs(long now) {
        if (phase != Phase.LISTENING) return limits.maxListenMs;
        return Math.max(0L, limits.maxListenMs - (now - liveAt));
    }

    public boolean start(long now) {
        if (active()) return false;
        phase = Phase.CONNECTING;
        stop = Stop.NONE;
        startedAt = now;
        liveAt = 0L;
        finishingAt = 0L;
        lastSpeechStoppedAt = 0L;
        speechActive = false;
        heardSpeech = false;
        commitSent = false;
        return true;
    }

    /** The data channel opened: audio is flowing to the transcriber. */
    public void onLive(long now) {
        if (phase != Phase.CONNECTING) return;
        phase = Phase.LISTENING;
        liveAt = now;
    }

    public void onSpeechStarted(long now) {
        if (!active()) return;
        speechActive = true;
        heardSpeech = true;
    }

    public void onSpeechStopped(long now) {
        if (!active()) return;
        speechActive = false;
        lastSpeechStoppedAt = now;
    }

    /** The buffer became an item (VAD after speech_stopped, or our own commit): speech is closed. */
    public void onCommitted(long now) {
        if (!active() || !speechActive) return;
        speechActive = false;
        lastSpeechStoppedAt = now;
    }

    /** A request to stop listening (user, limits, a voice session, the app pausing). */
    public Action stop(long now, Stop reason) {
        switch (phase) {
            case CONNECTING -> {
                phase = Phase.DONE;
                stop = reason;
                return Action.CLOSE;
            }
            case LISTENING -> {
                phase = Phase.FINISHING;
                stop = reason;
                finishingAt = now;
                return Action.MUTE;
            }
            default -> {
                return Action.NONE;
            }
        }
    }

    /** Drop everything now (BACK, cancel): no more words are wanted. */
    public Action cancel() {
        if (!active()) return Action.NONE;
        phase = Phase.DONE;
        stop = Stop.CANCELLED;
        return Action.CLOSE;
    }

    /** The peer or the runtime failed. */
    public Action fail() {
        if (!active()) return Action.NONE;
        phase = Phase.DONE;
        stop = Stop.FAILED;
        return Action.CLOSE;
    }

    /**
     * Called periodically. {@code pendingItems} = items heard but not transcribed to the end.
     * In FINISHING, {@link Action#CLOSE} means the transcript is as final as it will get.
     */
    public Action tick(long now, int pendingItems) {
        switch (phase) {
            case CONNECTING -> {
                if (now - startedAt >= limits.connectTimeoutMs) {
                    phase = Phase.DONE;
                    stop = Stop.FAILED;
                    return Action.CLOSE;
                }
                return Action.NONE;
            }
            case LISTENING -> {
                long listened = now - liveAt;
                if (listened >= limits.maxListenMs) return stop(now, Stop.MAX_DURATION);
                if (!heardSpeech && pendingItems == 0 && listened >= limits.noSpeechMs) {
                    return stop(now, Stop.NO_SPEECH);
                }
                if (heardSpeech && !speechActive && lastSpeechStoppedAt > 0L
                        && now - lastSpeechStoppedAt >= limits.trailingSilenceMs) {
                    return stop(now, Stop.SILENCE);
                }
                return Action.NONE;
            }
            case FINISHING -> {
                long waited = now - finishingAt;
                if (pendingItems == 0 && !speechActive) {
                    phase = Phase.DONE;
                    return Action.CLOSE;
                }
                if (waited >= FINISH_TIMEOUT_MS) {
                    phase = Phase.DONE;
                    return Action.CLOSE;
                }
                if (speechActive && !commitSent && waited >= COMMIT_AFTER_MS) {
                    commitSent = true;
                    return Action.COMMIT;
                }
                return Action.NONE;
            }
            default -> {
                return Action.NONE;
            }
        }
    }

    /** Back to IDLE after DONE, ready for another dictation. */
    public void reset() {
        if (active()) return;
        phase = Phase.IDLE;
    }
}
