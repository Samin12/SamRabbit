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
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/**
 * Records one voice note and sends it: the text fields' dictation with note limits (180 s cap, stop
 * ~2.5 s after the last words, nothing heard in 8 s = nothing sent), then the runtime's
 * {@code POST /v1/capture}, which keeps an outbox and hands the words to the Mac bridge. The
 * capture id is made when recording starts, so a resend is always the same note. Main thread only.
 *
 * <p>The words are never thrown away on the way: a runtime that doesn't answer (restarting, or slow
 * because the Mac is) gets the note kept in the app ({@link PendingNoteStore}) and offered again
 * with the same id every {@link NoteDelivery#RESEND_MS} until it takes it ({@link NoteDelivery}).
 * Once recording is over the user may take the screen back ({@link #sendInBackground}): the note
 * still goes, and its outcome comes later as a chip ({@link Listener#onVoiceNoteLater}).
 *
 * <p>Never speaks and never asks anything back: the overlay shows the result for a moment.
 * Transcripts are never logged (lengths and states only).
 */
public final class VoiceNoteController implements AutoCloseable {
    private static final String TAG = "SamVoiceNote";
    public static final DictationMachine.Limits LIMITS =
            new DictationMachine.Limits(180_000L, 8_000L, 2_500L, 15_000L);
    private static final long TICK_MS = 250L;
    /** Notes kept from an earlier run are offered again shortly after HOME starts. */
    private static final long FIRST_RESEND_MS = 5_000L;
    static final String KEPT_LINE = "On the R1. It goes to your Mac by itself.";
    static final String FAILED_LINE = "Couldn't save that note.";

    public interface Listener {
        /** Something on screen changed (phase, words, level). */
        void onVoiceNoteChanged();

        /** Recording or sending started (true) or is over (false): hold the microphone service, keep the screen on. */
        void onVoiceNoteActive(boolean active);

        /**
         * The outcome of a note that is no longer on screen (sent off screen, or resent later):
         * show it as a chip, never speak it. {@code ok} false for one that waits or failed.
         */
        void onVoiceNoteLater(String captureId, String line, boolean ok);
    }

    /** One note on its way to the runtime: its own copy (a new note may start meanwhile). */
    private static final class Outgoing {
        final PendingNote note;
        int attempts;

        Outgoing(PendingNote note) {
            this.note = note;
        }
    }

    private final Context context;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final VoiceNoteMachine machine = new VoiceNoteMachine();
    private final DictationSession dictation;
    private final RuntimeCaptureClient capture = new RuntimeCaptureClient();
    private final PendingNoteStore kept;
    /** Kept notes with a resend under way (never two at once for one note). */
    private final Set<String> resending = new HashSet<>();
    private final Runnable resend = this::resendKept;
    private final Runnable tick = this::tick;
    /** The note whose answer the overlay is waiting for (null once it went off screen). */
    private Outgoing foreground;
    private String words = "";
    private String captureId = "";
    private String capturedAt = "";
    private String trigger = "tap";
    private String resultKind = "";
    private boolean wasActive;
    private boolean previewing;
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
        kept = new PendingNoteStore(this.context);
        if (!kept.isEmpty()) main.postDelayed(resend, FIRST_RESEND_MS);
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
        captureId = UUID.randomUUID().toString();
        capturedAt = OffsetDateTime.now().truncatedTo(ChronoUnit.SECONDS).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME);
        if (DictationSession.anyActive()) {
            // A text sheet is dictating: two dictations would fight over the microphone.
            machine.onFailure("Another dictation has the microphone.", now);
            Log.i(TAG, "voice note not started (another dictation)");
        } else if (!dictation.start()) {
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

    /**
     * Finishing or sending: give the screen back and let the note carry on (a double press to talk,
     * a tap or BACK while it sends). Its outcome arrives as a chip. False while recording or idle.
     */
    public boolean sendInBackground() {
        if (previewing) return false;
        boolean sending = machine.phase() == VoiceNoteMachine.Phase.SENDING;
        if (!machine.toBackground(SystemClock.elapsedRealtime())) return false;
        if (sending) foreground = null; // its answer becomes a chip
        Log.i(TAG, "voice note goes on off screen (" + (sending ? "sending" : "finishing") + ")");
        changed();
        return true;
    }

    private void ended(String text, DictationMachine.Stop reason, String message) {
        long now = SystemClock.elapsedRealtime();
        if (reason == DictationMachine.Stop.CANCELLED) return;
        boolean offScreen = machine.background();
        if (reason == DictationMachine.Stop.FAILED && text.isBlank()) {
            machine.onFailure(message, now);
            Log.i(TAG, "voice note failed to record");
            if (offScreen) listener.onVoiceNoteLater(captureId, "Couldn't record it. Nothing was sent.", false);
            changed();
            return;
        }
        words = text;
        if (machine.onWords(text, now)) {
            Log.i(TAG, "voice note recorded reason=" + reason + " chars=" + text.length());
            Outgoing out = new Outgoing(new PendingNote(captureId, words, capturedAt, machine.durationMs(now), trigger,
                    System.currentTimeMillis()));
            foreground = offScreen ? null : out;
            submit(out);
        } else {
            Log.i(TAG, "voice note: nothing heard");
            if (offScreen) listener.onVoiceNoteLater(captureId, "I didn't catch anything. Nothing was sent.", false);
        }
        changed();
    }

    private void submit(Outgoing out) {
        PendingNote note = out.note;
        capture.submit(context, note.id, note.text, note.capturedAt, note.durationMs, note.trigger,
                new RuntimeCaptureClient.Callback() {
                    @Override public void onResult(JSONObject value) { delivered(out, value); }

                    @Override public void onFailure(int httpStatus, String code) { undelivered(out, httpStatus, code); }
                });
    }

    private void delivered(Outgoing out, JSONObject value) {
        kept.remove(out.note.id);
        String state = value.optString("state", "sent");
        String kind = value.optString("kind", "");
        Log.i(TAG, "voice note " + state + (kind.isEmpty() ? "" : " kind=" + kind));
        if (shown(out)) resultKind = kind;
        finish(out, state, value.optString("say", ""));
    }

    private void undelivered(Outgoing out, int httpStatus, String code) {
        switch (NoteDelivery.after(httpStatus, code, out.attempts)) {
            case RETRY -> {
                long delay = NoteDelivery.retryDelayMs(out.attempts++);
                main.postDelayed(() -> { if (!closed) submit(out); }, delay);
            }
            case KEEP -> {
                // Not taken yet (the runtime is restarting, or took it and is still waiting on the Mac):
                // keep the words here and offer them again with the same capture id.
                boolean saved = kept.put(out.note);
                Log.i(TAG, "voice note kept in the app: " + httpStatus + " " + code + (saved ? "" : " (not saved)"));
                if (saved) {
                    main.removeCallbacks(resend);
                    main.postDelayed(resend, NoteDelivery.RESEND_MS);
                    finish(out, "queued", KEPT_LINE);
                } else {
                    finish(out, "failed", FAILED_LINE);
                }
            }
            case FAILED -> {
                Log.w(TAG, "voice note not handed over: " + httpStatus + " " + code);
                finish(out, "failed", FAILED_LINE);
            }
        }
    }

    /** The answer for {@code out}: on the overlay while it waits for it, else a chip. */
    private void finish(Outgoing out, String state, String say) {
        if (shown(out)) {
            foreground = null;
            machine.onSent(state, say, SystemClock.elapsedRealtime());
            changed();
            return;
        }
        String line = say == null || say.isBlank() ? ("failed".equals(state) ? FAILED_LINE : "Sent to your Mac.") : say;
        listener.onVoiceNoteLater(out.note.id, line, "done".equals(state) || "sent".equals(state));
    }

    private boolean shown(Outgoing out) {
        return out == foreground && machine.phase() == VoiceNoteMachine.Phase.SENDING;
    }

    /** Offers every kept note to the runtime again (same capture id: it keeps one note per id). */
    private void resendKept() {
        main.removeCallbacks(resend);
        if (closed) return;
        List<PendingNote> notes = kept.all();
        if (notes.isEmpty()) return;
        for (PendingNote note : notes) {
            if (foreground != null && foreground.note.id.equals(note.id)) continue;
            if (!resending.add(note.id)) continue;
            capture.submit(context, note.id, note.text, note.capturedAt, note.durationMs, note.trigger,
                    new RuntimeCaptureClient.Callback() {
                        @Override public void onResult(JSONObject value) {
                            resending.remove(note.id);
                            kept.remove(note.id);
                            String state = value.optString("state", "sent");
                            Log.i(TAG, "kept voice note taken: " + state);
                            // Waiting or sending: the runtime announces the outcome itself later.
                            if (value.has("finishedAt") && NoteDelivery.worthAChip(state)) {
                                String say = value.optString("say", "");
                                boolean ok = "done".equals(state);
                                listener.onVoiceNoteLater(note.id, !say.isBlank() ? say : ok ? "Saved" : FAILED_LINE, ok);
                            }
                        }

                        @Override public void onFailure(int httpStatus, String code) {
                            resending.remove(note.id);
                            if (NoteDelivery.after(httpStatus, code, Integer.MAX_VALUE) == NoteDelivery.Next.FAILED) {
                                kept.remove(note.id);
                                Log.w(TAG, "kept voice note refused: " + httpStatus + " " + code);
                                listener.onVoiceNoteLater(note.id, FAILED_LINE, false);
                            }
                        }
                    });
        }
        main.postDelayed(resend, NoteDelivery.RESEND_MS);
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
