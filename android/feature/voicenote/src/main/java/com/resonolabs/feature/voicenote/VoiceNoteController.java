package com.resonolabs.feature.voicenote;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import com.resonolabs.feature.compose.DictationMachine;
import com.resonolabs.feature.compose.DictationSession;
import com.resonolabs.runtime.host.RuntimeCaptureClient;

import org.json.JSONObject;

import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/**
 * Records one voice note and sends it: the text fields' dictation with note limits (180 s cap, stop
 * ~2.5 s after the last words, nothing heard in 8 s = nothing sent), then the runtime's
 * {@code POST /v1/capture}, which keeps an outbox and hands the words to the Mac bridge. The
 * capture id is made when recording starts, so a resend is always the same note. Main thread only.
 *
 * <p>Never speaks and never asks anything back: the overlay shows the result for a moment.
 * Transcripts are never logged (lengths and states only).
 */
public final class VoiceNoteController implements AutoCloseable {
    private static final String TAG = "SamVoiceNote";
    public static final DictationMachine.Limits LIMITS =
            new DictationMachine.Limits(180_000L, 8_000L, 2_500L, 15_000L);
    private static final long TICK_MS = 250L;
    private static final long[] RETRY_MS = {1_500L, 4_000L};

    public interface Listener {
        /** Something on screen changed (phase, words, level). */
        void onVoiceNoteChanged();

        /** Recording or sending started (true) or is over (false): hold the microphone service, keep the screen on. */
        void onVoiceNoteActive(boolean active);
    }

    private final Context context;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final VoiceNoteMachine machine = new VoiceNoteMachine();
    private final DictationSession dictation;
    private final RuntimeCaptureClient capture = new RuntimeCaptureClient();
    private final Runnable tick = this::tick;
    private String words = "";
    private String captureId = "";
    private String capturedAt = "";
    private String trigger = "tap";
    private String resultKind = "";
    private boolean wasActive;
    private boolean previewing;
    private int sendAttempt;
    private boolean closed;

    public VoiceNoteController(Context context, BooleanSupplier voiceSessionLive, Listener listener) {
        this.context = context.getApplicationContext() != null ? context.getApplicationContext() : context;
        this.listener = listener;
        dictation = new DictationSession(this.context, voiceSessionLive, new DictationSession.Listener() {
            @Override public void onDictationPhase(DictationMachine.Phase phase) {
                if (phase == DictationMachine.Phase.LISTENING) machine.onLive(SystemClock.elapsedRealtime());
                changed();
            }

            @Override public void onDictationText(String text) {
                words = text == null ? "" : text;
                changed();
            }

            @Override public void onDictationEnded(String text, DictationMachine.Stop reason, String message) {
                ended(text == null ? "" : text, reason, message);
            }
        }, LIMITS);
    }

    public VoiceNoteMachine machine() {
        return machine;
    }

    /** Recording now (a gesture, a tap or the wheel finishes it). */
    public boolean recording() {
        return machine.recording();
    }

    /** From start until the runtime answered. */
    public boolean active() {
        return machine.active();
    }

    public boolean showing() {
        return machine.showing(SystemClock.elapsedRealtime());
    }

    /** The words heard so far (live, partial words may still change). */
    public String words() {
        return words;
    }

    /** journal | task | calendar | note once the Mac routed it, else "". */
    public String resultKind() {
        return resultKind;
    }

    public float level() {
        if (previewing && machine.phase() == VoiceNoteMachine.Phase.LISTENING) {
            // A believable voice level for debug screenshots (no microphone is open).
            return 0.35f + 0.3f * (float) Math.abs(Math.sin(SystemClock.uptimeMillis() / 180.0));
        }
        return dictation.level();
    }

    public long maxListenMs() {
        return LIMITS.maxListenMs;
    }

    /** Starts recording at once ({@code trigger}: triple_press | hold | tap). False while one runs. */
    public boolean start(String trigger) {
        if (previewing) debugPreview(null, "", "");
        if (closed || machine.active()) return false;
        long now = SystemClock.elapsedRealtime();
        if (!machine.start(now)) return false;
        this.trigger = trigger == null ? "tap" : trigger;
        words = "";
        resultKind = "";
        sendAttempt = 0;
        captureId = UUID.randomUUID().toString();
        capturedAt = OffsetDateTime.now().truncatedTo(ChronoUnit.SECONDS).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME);
        if (!dictation.start()) {
            machine.onFailure(dictation.available() ? "Couldn't start recording. Try again."
                    : "Voice chat has the microphone.", now);
            Log.i(TAG, "voice note not started (" + (dictation.available() ? "busy" : "voice session") + ")");
        } else {
            Log.i(TAG, "voice note started trigger=" + this.trigger);
        }
        changed();
        main.removeCallbacks(tick);
        main.postDelayed(tick, TICK_MS);
        return true;
    }

    /** Stop listening and send what was said (the last words still settle first). */
    public boolean finish() {
        if (previewing) {
            debugPreview(null, "", "");
            return true;
        }
        if (!machine.finish(SystemClock.elapsedRealtime())) return false;
        Log.i(TAG, "voice note finished by the user");
        dictation.stop();
        changed();
        return true;
    }

    /** BACK: drop it, nothing is sent. */
    public boolean cancel() {
        if (previewing) {
            debugPreview(null, "", "");
            return true;
        }
        if (!machine.cancel(SystemClock.elapsedRealtime())) return false;
        Log.i(TAG, "voice note cancelled");
        dictation.cancel();
        changed();
        return true;
    }

    /**
     * Debug screenshots only (DEBUG_NOTE, debug builds): shows {@code phase} with these words or
     * result line, with no microphone, no dictation and nothing sent. {@code phase} null hides it.
     */
    public void debugPreview(VoiceNoteMachine.Phase phase, String words, String line) {
        if (machine.recording() && !previewing) return; // never over a real note
        previewing = phase != null;
        this.words = words == null ? "" : words;
        machine.debugPreview(phase, line, SystemClock.elapsedRealtime());
        changed();
        main.removeCallbacks(tick);
        if (previewing) main.postDelayed(tick, TICK_MS);
    }

    /** A tap on a result closes it. */
    public void dismissResult() {
        machine.dismiss(SystemClock.elapsedRealtime());
        tick();
    }

    private void ended(String text, DictationMachine.Stop reason, String message) {
        long now = SystemClock.elapsedRealtime();
        if (reason == DictationMachine.Stop.CANCELLED) return;
        if (reason == DictationMachine.Stop.FAILED && text.isBlank()) {
            machine.onFailure(message, now);
            Log.i(TAG, "voice note failed to record");
            changed();
            return;
        }
        words = text;
        if (machine.onWords(text, now)) {
            Log.i(TAG, "voice note recorded reason=" + reason + " chars=" + text.length());
            send();
        } else {
            Log.i(TAG, "voice note: nothing heard");
        }
        changed();
    }

    private void send() {
        long duration = machine.durationMs(SystemClock.elapsedRealtime());
        capture.submit(context, captureId, words, capturedAt, duration, trigger, new RuntimeCaptureClient.Callback() {
            @Override public void onResult(JSONObject value) {
                String state = value.optString("state", "sent");
                resultKind = value.optString("kind", "");
                machine.onSent(state, value.optString("say", ""), SystemClock.elapsedRealtime());
                Log.i(TAG, "voice note " + state + (resultKind.isEmpty() ? "" : " kind=" + resultKind));
                changed();
            }

            @Override public void onFailure(int httpStatus, String code) {
                if (httpStatus == 0 && sendAttempt < RETRY_MS.length) {
                    long delay = RETRY_MS[sendAttempt++];
                    main.postDelayed(() -> { if (!closed) send(); }, delay);
                    return;
                }
                Log.w(TAG, "voice note not handed over: " + httpStatus + " " + code);
                machine.onSent("failed", httpStatus == 0 ? "The R1's assistant isn't ready. Note not saved."
                        : "Couldn't save that note.", SystemClock.elapsedRealtime());
                changed();
            }
        });
    }

    private void tick() {
        if (closed) return;
        long now = SystemClock.elapsedRealtime();
        boolean changed = machine.tick(now);
        if (changed || machine.showing(now)) changed();
        if (machine.showing(now)) main.postDelayed(tick, TICK_MS);
    }

    private void changed() {
        boolean active = machine.active() && !previewing;
        if (active != wasActive) {
            wasActive = active;
            listener.onVoiceNoteActive(active);
        }
        listener.onVoiceNoteChanged();
    }

    @Override public void close() {
        closed = true;
        main.removeCallbacksAndMessages(null);
        if (machine.recording()) dictation.cancel();
        capture.close();
    }
}
