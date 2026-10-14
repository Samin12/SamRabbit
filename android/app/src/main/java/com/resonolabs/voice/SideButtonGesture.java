package com.resonolabs.voice;

import android.content.ComponentName;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.content.res.Resources;
import android.provider.Settings;
import android.util.Log;

import com.resonolabs.ui.power.SideButtonSetting;

/**
 * Side button (KEYCODE_POWER) double press → Voice toggle; triple press or hold → voice note.
 *
 * <p>The framework owns the power key: PhoneWindowManager never passes it to apps. The
 * {@code com.resonolabs.overlay.powerbutton} RRO (android/system/power-overlay) sets
 * {@code config_doublePressOnPowerBehavior=3}, so on the second key-down of a double press
 * (down-to-down &lt; 300 ms, fixed by the framework) PWM starts the non-exported
 * {@code .SideButtonToggle} activity-alias of {@link MainActivity} as uid 1000. The alias component
 * in the delivered intent is what tells a double press apart from any other HOME launch.
 *
 * <p>Voice note (Settings &gt; Side button: Triple press / Hold / Both):
 * <ul>
 *   <li>Triple press: the overlay sets {@code config_triplePressOnPowerBehavior=1} (theater mode)
 *   and {@code config_goToSleepOnButtonPressTheaterMode=false}, so the third quick press only flips
 *   {@code Settings.Global theater_mode_on} to 1. MainActivity watches it, writes 0 back at once
 *   and starts the note. A triple press can't be another launch of the toggle alias: PWM would
 *   start the same component with no extras. While the triple is on, the double press fires
 *   ~0.3 s after the second release instead of on the second press.</li>
 *   <li>Hold: {@code power_button_long_press=4} makes a 0.5 s hold start
 *   {@code android.intent.action.VOICE_ASSIST}, which only the {@code .SideButtonVoiceNote} alias
 *   handles; {@code power_button_very_long_press=1} keeps the power menu at a 3.5 s hold.</li>
 * </ul>
 * The app owns these Global keys ({@link #checkFrameworkPolicy}); the triple is never enabled
 * while the theater config still puts the screen to sleep (a new APK on an old overlay, before
 * the restart that loads the new one).
 */
final class SideButtonGesture {
    static final String LOG_TAG = "SamSideButton";
    /** Class name of the activity-alias in AndroidManifest.xml (no build-type suffix). */
    static final String TOGGLE_ALIAS = "com.resonolabs.voice.SideButtonToggle";
    /** PhoneWindowManager.MULTI_PRESS_POWER_LAUNCH_TARGET_ACTIVITY. */
    static final String LAUNCH_TARGET_ACTIVITY = "3";
    static final String DOUBLE_PRESS_SETTING = "power_button_double_press";
    /** Class name of the hold (VOICE_ASSIST) alias. */
    static final String VOICE_NOTE_ALIAS = "com.resonolabs.voice.SideButtonVoiceNote";
    static final String VOICE_ASSIST = "android.intent.action.VOICE_ASSIST";
    static final String THEATER_SETTING = "theater_mode_on";
    static final String TRIPLE_PRESS_SETTING = "power_button_triple_press";
    static final String LONG_PRESS_SETTING = "power_button_long_press";
    static final String VERY_LONG_PRESS_SETTING = "power_button_very_long_press";
    /** PhoneWindowManager.MULTI_PRESS_POWER_THEATER_MODE / MULTI_PRESS_POWER_NOTHING. */
    static final String THEATER_MODE = "1";
    static final String MULTI_PRESS_NOTHING = "0";
    /** LONG_PRESS_POWER_GO_TO_VOICE_ASSIST and VERY_LONG_PRESS_POWER_GLOBAL_ACTIONS. */
    static final String LONG_PRESS_VOICE_ASSIST = "4";
    static final String VERY_LONG_PRESS_GLOBAL_ACTIONS = "1";
    /** One note gesture can arrive twice (a theater flip and a resume); real ones are seconds apart. */
    static final long MIN_NOTE_INTERVAL_MS = 700L;
    /**
     * Two genuine double presses are always more than 300 ms apart (a third press inside the window
     * only raises PWM's press counter), so this only drops duplicate deliveries of one gesture.
     */
    static final long MIN_TOGGLE_INTERVAL_MS = 300L;

    private long lastToggleAt = Long.MIN_VALUE;
    private long lastNoteAt = Long.MIN_VALUE;

    static boolean isToggle(Intent intent) {
        if (intent == null) return false;
        ComponentName component = intent.getComponent();
        return component != null && isToggleClassName(component.getClassName());
    }

    static boolean isToggleClassName(String className) {
        return TOGGLE_ALIAS.equals(className);
    }

    /** The hold gesture: PWM's VOICE_ASSIST start, resolved to the {@code .SideButtonVoiceNote} alias. */
    static boolean isVoiceNote(Intent intent) {
        if (intent == null) return false;
        ComponentName component = intent.getComponent();
        if (component != null && VOICE_NOTE_ALIAS.equals(component.getClassName())) return true;
        return VOICE_ASSIST.equals(intent.getAction());
    }

    /** {@code theater_mode_on} just became 1: the triple-press signal. */
    static boolean isTripleSignal(String value) {
        return value != null && THEATER_MODE.equals(value.trim());
    }

    /**
     * The {@code power_button_triple_press} value to enforce. Never the theater behaviour while
     * {@code config_goToSleepOnButtonPressTheaterMode} resolves true (or can't be read): a triple
     * would then turn the screen off.
     */
    static String tripleSetting(Boolean goToSleepOnTheater, boolean wanted) {
        if (!wanted || goToSleepOnTheater == null || goToSleepOnTheater) return MULTI_PRESS_NOTHING;
        return THEATER_MODE;
    }

    /** What Settings &gt; Side button says about the triple on this boot. */
    static SideButtonSetting.TripleState tripleState(Boolean goToSleepOnTheater, Integer tripleConfig) {
        if (goToSleepOnTheater == null || tripleConfig == null) return SideButtonSetting.TripleState.UNAVAILABLE;
        if (goToSleepOnTheater || tripleConfig != 1) return SideButtonSetting.TripleState.NEEDS_RESTART;
        return SideButtonSetting.TripleState.READY;
    }

    /**
     * The Global long-press keys for the hold gesture: our values while it is on; otherwise null
     * (the framework default: a 0.5 s hold opens the power menu), but only where the value is still
     * ours, so a setting someone else wrote is left alone. Returns {@code current} for "leave it".
     */
    static String longPressSetting(boolean hold, String current, String ours) {
        if (hold) return ours;
        return current != null && ours.equals(current.trim()) ? null : current;
    }

    /** Debounce for one voice-note gesture. Returns false when {@code nowMs} is a duplicate. */
    boolean acceptNote(long nowMs) {
        if (lastNoteAt != Long.MIN_VALUE && nowMs - lastNoteAt < MIN_NOTE_INTERVAL_MS) return false;
        lastNoteAt = nowMs;
        return true;
    }

    /** {@code <package>/<alias>} exactly as the overlay must spell config_doublePressOnPowerTargetActivity. */
    static String overlayTargetFor(String packageName) {
        return packageName + "/" + TOGGLE_ALIAS;
    }

    /**
     * Whether to rewrite {@code Settings.Global power_button_double_press}. PWM reads that key live
     * and it beats the overlay's default, so a stale 0 (e.g. a settings toggle) would silently
     * disable the gesture. Only touch it when the overlay is really pointing at this app, an
     * explicit value exists and it is not already the launch-target behaviour.
     */
    static boolean shouldRestoreDoublePress(String overlayTarget, String expectedTarget, String current) {
        if (overlayTarget == null || !overlayTarget.equals(expectedTarget)) return false;
        return current != null && !LAUNCH_TARGET_ACTIVITY.equals(current.trim());
    }

    /** Debounce for one physical gesture. Returns false when {@code nowMs} is a duplicate. */
    boolean accept(long nowMs) {
        if (lastToggleAt != Long.MIN_VALUE && nowMs - lastToggleAt < MIN_TOGGLE_INTERVAL_MS) return false;
        lastToggleAt = nowMs;
        return true;
    }

    /**
     * Logs the live framework policy and repairs an overriding Global setting. Never throws: on a
     * device without the overlay this only logs that the gesture is unavailable.
     */
    static void checkFrameworkPolicy(Context context) {
        try {
            String expected = overlayTargetFor(context.getPackageName());
            String target = frameworkString(context.getResources(), "config_doublePressOnPowerTargetActivity");
            ContentResolver resolver = context.getContentResolver();
            String current = Settings.Global.getString(resolver, DOUBLE_PRESS_SETTING);
            if (shouldRestoreDoublePress(target, expected, current)) {
                Settings.Global.putString(resolver, DOUBLE_PRESS_SETTING, LAUNCH_TARGET_ACTIVITY);
                Log.i(LOG_TAG, DOUBLE_PRESS_SETTING + " was " + current + "; restored "
                        + LAUNCH_TARGET_ACTIVITY);
            }
            Log.i(LOG_TAG, "double press " + (expected.equals(target) ? "ready" : "unavailable")
                    + ": target=" + (target == null || target.isEmpty() ? "<none>" : target)
                    + " setting=" + current);
        } catch (RuntimeException error) {
            Log.w(LOG_TAG, "double press policy check failed: " + error);
        }
        applyVoiceNotePolicy(context);
    }

    /**
     * Enforces Settings &gt; Side button on the framework's live Global keys (triple press and the
     * long presses) and resets a stale {@code theater_mode_on=1} (from a press while HOME was not
     * running) without acting on it. Never throws.
     */
    static void applyVoiceNotePolicy(Context context) {
        try {
            ContentResolver resolver = context.getContentResolver();
            Resources resources = context.getResources();
            SideButtonSetting.VoiceNote choice = SideButtonSetting.voiceNote(context);
            Boolean sleeps = frameworkBool(resources, "config_goToSleepOnButtonPressTheaterMode");
            Integer tripleConfig = frameworkInteger(resources, "config_triplePressOnPowerBehavior");
            SideButtonSetting.TripleState state = tripleState(sleeps, tripleConfig);
            SideButtonSetting.reportTripleState(state);
            String triple = tripleSetting(sleeps, choice.triple());
            String currentTriple = Settings.Global.getString(resolver, TRIPLE_PRESS_SETTING);
            if (!triple.equals(currentTriple == null ? null : currentTriple.trim())) {
                Settings.Global.putString(resolver, TRIPLE_PRESS_SETTING, triple);
            }
            putIfChanged(resolver, LONG_PRESS_SETTING, longPressSetting(choice.hold(),
                    Settings.Global.getString(resolver, LONG_PRESS_SETTING), LONG_PRESS_VOICE_ASSIST));
            putIfChanged(resolver, VERY_LONG_PRESS_SETTING, longPressSetting(choice.hold(),
                    Settings.Global.getString(resolver, VERY_LONG_PRESS_SETTING), VERY_LONG_PRESS_GLOBAL_ACTIONS));
            if (isTripleSignal(Settings.Global.getString(resolver, THEATER_SETTING))) {
                Settings.Global.putInt(resolver, THEATER_SETTING, 0);
                Log.i(LOG_TAG, "stale theater_mode_on reset");
            }
            Log.i(LOG_TAG, "voice note gesture " + choice + ": triple=" + triple + " (" + state + ") hold="
                    + choice.hold());
        } catch (RuntimeException error) {
            Log.w(LOG_TAG, "voice note policy check failed: " + error);
        }
    }

    private static void putIfChanged(ContentResolver resolver, String key, String value) {
        String current = Settings.Global.getString(resolver, key);
        if (value == null ? current == null : value.equals(current)) return;
        Settings.Global.putString(resolver, key, value);
    }

    @SuppressWarnings("DiscouragedApi") // Framework config, read by name.
    private static Boolean frameworkBool(Resources resources, String name) {
        int id = resources.getIdentifier(name, "bool", "android");
        if (id == 0) return null;
        try {
            return resources.getBoolean(id);
        } catch (Resources.NotFoundException missing) {
            return null;
        }
    }

    @SuppressWarnings("DiscouragedApi") // Framework config, read by name.
    private static Integer frameworkInteger(Resources resources, String name) {
        int id = resources.getIdentifier(name, "integer", "android");
        if (id == 0) return null;
        try {
            return resources.getInteger(id);
        } catch (Resources.NotFoundException missing) {
            return null;
        }
    }

    @SuppressWarnings("DiscouragedApi") // The config is internal to the framework; read by name.
    private static String frameworkString(Resources resources, String name) {
        int id = resources.getIdentifier(name, "string", "android");
        return id == 0 ? null : resources.getString(id);
    }
}
