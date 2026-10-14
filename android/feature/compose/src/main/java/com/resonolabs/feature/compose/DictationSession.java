package com.resonolabs.feature.compose;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;

import com.resonolabs.runtime.host.RuntimeDictationClient;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.function.BooleanSupplier;

/**
 * One dictation at a time: microphone → runtime speech-to-text call → words. Streams the running
 * text (partial + final) to the listener and ends with the settled words. Default limits
 * ({@link DictationMachine.Limits#DEFAULT}): 60 s of listening, auto-stop after ~4.7 s of quiet once
 * something was said (server VAD), and after 8 s when nothing was said. Never runs while a voice session is live (the shared microphone and
 * the assistant would hear the dictation): {@link #start()} refuses, and a voice session that
 * starts mid-dictation stops it. Main thread only.
 */
public final class DictationSession {
    private static final String LOG_TAG = "SamDictation";
    private static final long TICK_MS = 200L;

    public interface Listener {
        void onDictationPhase(DictationMachine.Phase phase);
        /** The words so far (partial words may still change). */
        void onDictationText(String words);
        /** Over: the settled words ("" when nothing was heard), why it stopped, and a short message for failures. */
        void onDictationEnded(String words, DictationMachine.Stop reason, String message);
    }

    /** Dictations listening or finishing right now, in any sheet or voice note (main thread). */
    private static int activeCount;

    private final Context context;
    private final BooleanSupplier voiceSessionLive;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final DictationMachine machine;
    private final DictationTranscript transcript = new DictationTranscript();
    private final DictationEvents events = new DictationEvents();
    private final Runnable tick = this::tick;
    private RuntimeDictationClient client;
    private DictationPeer peer;
    private String failure = "";
    private String lastText = "";
    private boolean counted;

    public DictationSession(Context context, BooleanSupplier voiceSessionLive, Listener listener) {
        this(context, voiceSessionLive, listener, DictationMachine.Limits.DEFAULT);
    }

    /** A dictation with its own limits (a voice note listens longer and stops sooner after the words). */
    public DictationSession(Context context, BooleanSupplier voiceSessionLive, Listener listener,
                            DictationMachine.Limits limits) {
        this.context = context.getApplicationContext();
        this.voiceSessionLive = voiceSessionLive;
        this.listener = listener;
        this.machine = new DictationMachine(limits);
    }

    /** True while any dictation holds the microphone (the screen stays on meanwhile). */
    public static boolean anyActive() {
        return activeCount > 0;
    }

    public DictationMachine.Phase phase() {
        return machine.phase();
    }

    public boolean active() {
        return machine.active();
    }

    public boolean speechActive() {
        return machine.speechActive();
    }

    /** Microphone level 0..1 while listening. */
    public float level() {
        return peer == null || machine.phase() != DictationMachine.Phase.LISTENING ? 0f : peer.level();
    }

    public long remainingMs() {
        return machine.remainingMs(SystemClock.elapsedRealtime());
    }

    /** True when dictation may start now (no voice session holds the microphone). */
    public boolean available() {
        return !voiceSessionLive.getAsBoolean();
    }

    /** Opens the microphone. False when already dictating or while a voice session is live. */
    public boolean start() {
        if (machine.active() || !available()) return false;
        long now = SystemClock.elapsedRealtime();
        machine.reset();
        if (!machine.start(now)) return false;
        transcript.clear();
        failure = "";
        lastText = "";
        client = new RuntimeDictationClient();
        peer = new DictationPeer(context, new DictationPeer.Listener() {
            @Override public void onOffer(String sdp) {
                RuntimeDictationClient current = client;
                if (current == null || !machine.active()) return;
                current.createCall(context, sdp, new RuntimeDictationClient.Callback() {
                    @Override public void onAnswer(String answer, String sessionId, String mode) {
                        if (peer != null && machine.phase() == DictationMachine.Phase.CONNECTING) peer.applyAnswer(answer);
                    }

                    @Override public void onFailure(String reason) {
                        failWith(describe(reason));
                    }
                });
            }

            @Override public void onLive() {
                machine.onLive(SystemClock.elapsedRealtime());
                listener.onDictationPhase(machine.phase());
            }

            @Override public void onEvent(String json) {
                handle(json);
            }

            @Override public void onFailure(String reason) {
                failWith(describe(reason));
            }
        });
        listener.onDictationPhase(machine.phase());
        if (!counted) {
            counted = true;
            activeCount++;
        }
        peer.start();
        main.postDelayed(tick, TICK_MS);
        Log.i(LOG_TAG, "dictation started");
        return true;
    }

    /** User tap: stop listening, keep the words still being transcribed. */
    public void stop() {
        perform(machine.stop(SystemClock.elapsedRealtime(), DictationMachine.Stop.USER));
    }

    /** The app went to the background or the screen turned off. */
    public void pause() {
        perform(machine.stop(SystemClock.elapsedRealtime(), DictationMachine.Stop.PAUSED));
    }

    /** Throw it all away now (the sheet was cancelled or closed). No ended callback. */
    public void cancel() {
        if (machine.cancel() == DictationMachine.Action.CLOSE) release();
    }

    private void handle(String json) {
        long now = SystemClock.elapsedRealtime();
        switch (events.apply(json, transcript, machine, now)) {
            case TEXT -> publishText();
            case SPEECH -> listener.onDictationPhase(machine.phase());
            case RESPONSE_STARTED -> {
                // Dictation sessions never create responses; if one appears anyway, cancel it.
                try {
                    if (peer != null) peer.send(new JSONObject().put("type", "response.cancel"));
                } catch (JSONException ignored) {
                    // A constant object cannot fail to build.
                }
            }
            case ERROR -> {
                Log.w(LOG_TAG, "dictation server error: " + events.lastError());
                if (machine.phase() == DictationMachine.Phase.FINISHING) perform(DictationMachine.Action.CLOSE);
                else failWith("Dictation stopped: " + shorten(events.lastError()));
            }
            default -> { }
        }
    }

    private void tick() {
        if (!machine.active()) return;
        long now = SystemClock.elapsedRealtime();
        DictationMachine.Phase phase = machine.phase();
        if (voiceSessionLive.getAsBoolean()) {
            if (phase == DictationMachine.Phase.CONNECTING || phase == DictationMachine.Phase.LISTENING) {
                perform(machine.stop(now, DictationMachine.Stop.VOICE_SESSION));
            }
            // The voice session owns the microphone from now on: release the capture at once, even
            // while the last words are still being transcribed (FINISHING keeps the call, not the mic).
            // A side-button double press pauses the activity first, so FINISHING is the usual phase.
            if (peer != null) peer.stopCapture();
        }
        DictationMachine.Action action = machine.tick(now, transcript.pending());
        if (action == DictationMachine.Action.CLOSE && machine.stopReason() == DictationMachine.Stop.FAILED
                && failure.isEmpty()) {
            failure = "Couldn't reach dictation. Try again.";
        }
        perform(action);
        if (machine.active()) main.postDelayed(tick, TICK_MS);
    }

    private void perform(DictationMachine.Action action) {
        switch (action) {
            case MUTE -> {
                if (peer != null) peer.muteMicrophone();
                listener.onDictationPhase(machine.phase());
            }
            case COMMIT -> {
                try {
                    if (peer != null) peer.send(new JSONObject().put("type", "input_audio_buffer.commit"));
                } catch (JSONException ignored) {
                    // A constant object cannot fail to build.
                }
            }
            case CLOSE -> finish();
            default -> { }
        }
    }

    private void failWith(String message) {
        if (!machine.active()) return;
        failure = message;
        perform(machine.fail());
    }

    private void finish() {
        transcript.settleAll();
        String words = transcript.text();
        DictationMachine.Stop reason = machine.stopReason();
        release();
        Log.i(LOG_TAG, "dictation ended reason=" + reason + " chars=" + words.length());
        if (!words.equals(lastText)) {
            lastText = words;
            listener.onDictationText(words);
        }
        listener.onDictationEnded(words, reason, reason == DictationMachine.Stop.FAILED ? failure : "");
        listener.onDictationPhase(machine.phase());
    }

    private void release() {
        if (counted) {
            counted = false;
            activeCount = Math.max(0, activeCount - 1);
        }
        main.removeCallbacks(tick);
        if (peer != null) {
            peer.close();
            peer = null;
        }
        if (client != null) {
            client.close();
            client = null;
        }
    }

    private void publishText() {
        String words = transcript.text();
        if (words.equals(lastText)) return;
        lastText = words;
        listener.onDictationText(words);
    }

    /** A short, human message for a runtime/peer failure code. */
    static String describe(String reason) {
        String code = reason == null ? "" : reason;
        int colon = code.indexOf(':');
        if (colon >= 0) code = code.substring(0, colon);
        return switch (code) {
            case "credential_unavailable", "credential_rejected" -> "Connect OpenAI in Settings to dictate.";
            case "model_required", "provider_unavailable" -> "Dictation isn't set up. Check AI settings.";
            case "runtime-unavailable" -> "The assistant runtime isn't ready yet.";
            case "peer-start-failed" -> "Couldn't open the microphone.";
            case "ice-failed", "data-channel-closed", "answer-rejected" -> "Lost the connection. Try again.";
            default -> "Couldn't start dictation. Try again.";
        };
    }

    private static String shorten(String message) {
        if (message == null || message.isBlank()) return "error";
        return message.length() > 60 ? message.substring(0, 59) + "…" : message;
    }
}
