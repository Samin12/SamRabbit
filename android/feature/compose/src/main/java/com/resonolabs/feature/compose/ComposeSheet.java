package com.resonolabs.feature.compose;

import android.app.Activity;
import android.app.Application;
import android.app.Dialog;
import android.content.pm.ApplicationInfo;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;

import com.resonolabs.ui.input.HardwareInputRouter;
import com.resonolabs.ui.input.UiInputIntent;

import java.util.function.BooleanSupplier;

/**
 * Type or dictate: the one text-entry sheet of SamRabbit. A full-screen glass sheet with a
 * context line, a multi-line field (AOSP keyboard) and a big microphone. Tap the mic and talk:
 * the words stream into the field at the cursor (live, as they are recognized), so typing and
 * talking mix freely. Send/Done hands the trimmed text over; Cancel, BACK or a swipe in from
 * the left edge discards it.
 *
 * <p>Keyboard-aware: with the keyboard up (it covers ~3/4 of the R1 screen) the sheet is a
 * compact bar above it ([✕] context / [field] [mic] [send]); without it, the full sheet with the
 * big mic orb and Cancel / Type / Send.
 *
 * <p>One-line adoption: {@code ComposeSheet.open(activity, "Reply to …", "Send", text -> …)}.
 * Voice-first or limits: {@code ComposeSheet.open(activity, new ComposeSheet.Options()
 * .title("Note for today's journal").action("Add").voiceFirst(true).maxLength(2000), text -> …)}.
 *
 * <p>Dictation never runs while a voice session is live: the shell registers
 * {@link #setVoiceSessionProbe}; the mic then explains that voice chat is on (and a voice session
 * that starts mid-dictation stops it). Secret fields ({@link Options#secret}) are keyboard-only.
 */
public final class ComposeSheet extends Dialog {
    private static final String LOG_TAG = "SamCompose";
    /** Debug builds: {@code adb shell setprop debug.sam.compose.voicefirst 1} opens every sheet voice-first. */
    static final String VOICE_FIRST_PROPERTY = "debug.sam.compose.voicefirst";

    public interface Submit {
        void text(String value);
    }

    /** What the sheet asks for and how it opens. */
    public static final class Options {
        String title = "";
        String hint = "";
        String action = "Send";
        String initialText = "";
        int maxLength;
        boolean voiceFirst;
        boolean secret;

        /** Context line, e.g. "Reply to “Fix login”". */
        public Options title(String value) {
            title = value == null ? "" : value;
            return this;
        }

        /** Placeholder inside the empty field (defaults to "Type or tap the mic"). */
        public Options hint(String value) {
            hint = value == null ? "" : value;
            return this;
        }

        /** Label of the submit button and keyboard action ("Send", "Start", "Save", …). */
        public Options action(String value) {
            action = value == null || value.isBlank() ? "Send" : value;
            return this;
        }

        public Options initialText(String value) {
            initialText = value == null ? "" : value;
            return this;
        }

        /** Character limit for typed and dictated text; {@code <= 0} = none. */
        public Options maxLength(int value) {
            maxLength = Math.max(0, value);
            return this;
        }

        /** Open listening (dictation starts at once) instead of with the keyboard. */
        public Options voiceFirst(boolean value) {
            voiceFirst = value;
            return this;
        }

        /** Password-style: masked, keyboard only, no dictation (secrets are never sent to transcription). */
        public Options secret(boolean value) {
            secret = value;
            return this;
        }
    }

    private static volatile BooleanSupplier voiceProbe = () -> false;
    /** Sheets on screen right now (main thread): HOME keeps the screen on while one is open. */
    private static int shown;

    /** The shell tells every sheet whether a voice session (which owns the microphone) is live. */
    public static void setVoiceSessionProbe(BooleanSupplier probe) {
        voiceProbe = probe == null ? () -> false : probe;
    }

    /** True while any sheet is on screen (typing in it never reaches HOME's own input). */
    public static boolean anyOpen() {
        return shown > 0;
    }

    /** Keyboard-first sheet with a context line and an action label. */
    public static ComposeSheet open(Activity activity, String title, String action, Submit submit) {
        return open(activity, new Options().title(title).action(action), submit);
    }

    public static ComposeSheet open(Activity activity, Options options, Submit submit) {
        ComposeSheet sheet = new ComposeSheet(activity, options, submit);
        sheet.show();
        return sheet;
    }

    private final Activity activity;
    private final ComposeSheetView view;
    private final Application.ActivityLifecycleCallbacks lifecycle = new Application.ActivityLifecycleCallbacks() {
        @Override public void onActivityPaused(Activity paused) {
            if (paused == activity) view.onHostPaused();
        }
        @Override public void onActivityCreated(Activity a, Bundle b) { }
        @Override public void onActivityStarted(Activity a) { }
        @Override public void onActivityResumed(Activity a) { }
        @Override public void onActivityStopped(Activity a) { }
        @Override public void onActivitySaveInstanceState(Activity a, Bundle b) { }
        @Override public void onActivityDestroyed(Activity a) { }
    };
    private boolean lifecycleRegistered;
    private boolean counted;

    private ComposeSheet(Activity activity, Options options, Submit submit) {
        super(activity, android.R.style.Theme_DeviceDefault_NoActionBar_Fullscreen);
        this.activity = activity;
        Options effective = options == null ? new Options() : options;
        if (!effective.secret && debugVoiceFirst(activity)) effective.voiceFirst = true;
        view = new ComposeSheetView(activity, this, effective, submit, () -> voiceProbe.getAsBoolean());
        setContentView(view);
        setCancelable(true);
        setCanceledOnTouchOutside(false);
        setOnCancelListener(ignored -> view.onCancelled());
        Window window = getWindow();
        if (window != null) {
            window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            window.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
            window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            // We read the keyboard's height from the insets and lay out around it ourselves.
            window.setDecorFitsSystemWindows(false);
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                    | (effective.voiceFirst ? WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
                    : WindowManager.LayoutParams.SOFT_INPUT_STATE_UNSPECIFIED));
        }
    }

    @Override protected void onStart() {
        super.onStart();
        hideSystemBars();
        if (!lifecycleRegistered) {
            activity.registerActivityLifecycleCallbacks(lifecycle);
            lifecycleRegistered = true;
        }
        if (!counted) {
            counted = true;
            shown++;
        }
        view.onShown();
    }

    @Override protected void onStop() {
        if (lifecycleRegistered) {
            activity.unregisterActivityLifecycleCallbacks(lifecycle);
            lifecycleRegistered = false;
        }
        if (counted) {
            counted = false;
            shown = Math.max(0, shown - 1);
        }
        view.onClosed();
        super.onStop();
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        if (event.getKeyCode() != KeyEvent.KEYCODE_BACK && view.wantsHardwareKeys()) {
            UiInputIntent intent = HardwareInputRouter.keyIntent(event.getKeyCode());
            if (intent != null) {
                if (event.getAction() == KeyEvent.ACTION_DOWN) view.onInput(intent);
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean dispatchGenericMotionEvent(MotionEvent event) {
        UiInputIntent intent = HardwareInputRouter.motionIntent(event);
        if (intent != null && view.wantsHardwareKeys()) {
            view.onInput(intent);
            return true;
        }
        return super.dispatchGenericMotionEvent(event);
    }

    private void hideSystemBars() {
        Window window = getWindow();
        if (window == null) return;
        WindowInsetsController controller = window.getInsetsController();
        if (controller == null) return;
        controller.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
        controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    private static boolean debugVoiceFirst(Activity activity) {
        if ((activity.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return false;
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Object value = properties.getMethod("get", String.class, String.class)
                    .invoke(null, VOICE_FIRST_PROPERTY, "");
            boolean on = "1".equals(String.valueOf(value).trim());
            if (on) Log.i(LOG_TAG, VOICE_FIRST_PROPERTY + "=1: opening voice-first");
            return on;
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            return false;
        }
    }
}
