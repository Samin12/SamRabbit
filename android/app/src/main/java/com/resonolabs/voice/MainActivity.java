package com.resonolabs.voice;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.database.ContentObserver;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;

import com.resonolabs.ui.power.DisplayPolicy;
import com.resonolabs.ui.power.IdleScreenPolicy;
import com.resonolabs.ui.power.SideButtonSetting;
import com.resonolabs.runtime.host.RuntimeHealthClient;
import com.resonolabs.runtime.host.RuntimeManagementClient;
import com.resonolabs.runtime.host.RuntimeService;
import com.resonolabs.feature.settings.ManagementPairingState;
import com.resonolabs.runtime.host.RuntimeBackgroundRunClient;
import com.resonolabs.runtime.host.RuntimeCreationImportClient;

public final class MainActivity extends Activity {
    /** The live HOME instance, for debug-only entry points (VoiceDebugReceiver). */
    private static java.lang.ref.WeakReference<MainActivity> current = new java.lang.ref.WeakReference<>(null);
    private ProductRootView root;
    private RuntimeHealthClient runtimeHealth;
    private RuntimeManagementClient runtimeManagement;
    private RuntimeBackgroundRunClient backgroundRuns;
    private RuntimeCreationImportClient creationImports;
    private final SideButtonGesture sideButton = new SideButtonGesture();
    /** Cold start through the side-button alias: start Voice once the runtime answers. */
    private boolean sideButtonStartPending;
    private boolean screenOffRegistered;
    /** Owns FLAG_KEEP_SCREEN_ON: the screen goes off after 10 min with nothing going on. */
    private IdleScreenPolicy idle;
    private boolean resumed;
    /** A voice-note gesture that arrived before HOME was resumed (the mic needs a TOP process). */
    private String voiceNotePending;
    private long voiceNotePendingAt;
    /** A pending note older than this is dropped (HOME never came to the front in time). */
    private static final long NOTE_PENDING_MAX_MS = 6_000L;
    /** Cold start through the hold alias: start the note once the runtime answers. */
    private boolean noteAfterRuntime;
    private boolean theaterRegistered;
    /** Triple press: PWM flips theater_mode_on to 1; reset it at once and start the note. */
    private final ContentObserver theater = new ContentObserver(new Handler(Looper.getMainLooper())) {
        @Override public void onChange(boolean selfChange) {
            String value = Settings.Global.getString(getContentResolver(), SideButtonGesture.THEATER_SETTING);
            if (!SideButtonGesture.isTripleSignal(value)) return; // our own reset to 0
            try {
                Settings.Global.putInt(getContentResolver(), SideButtonGesture.THEATER_SETTING, 0);
            } catch (RuntimeException error) {
                Log.w(SideButtonGesture.LOG_TAG, "theater mode reset failed: " + error);
            }
            onVoiceNoteGesture("triple_press");
        }
    };
    private final Runnable sideButtonChanged = () -> runOnUiThread(() -> {
        SideButtonGesture.applyVoiceNotePolicy(this);
        if (root != null) root.refreshSideButtonHint();
    });
    private final BroadcastReceiver screenOn = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (idle != null) idle.onResume();
            if (root != null) root.showLateChip(); // a voice-note outcome that came in the dark
        }
    };
    private final BroadcastReceiver screenOff = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (root == null) return;
            // SCREEN_OFF reaches HOME ~1 s after the panel goes off. If a press already woke the
            // screen again (e.g. a quick double press that just started a new session) the mic
            // is usable again: ending the session now would kill the one the user asked for.
            PowerManager power = getSystemService(PowerManager.class);
            if (power != null && power.isInteractive()) {
                Log.i(SideButtonGesture.LOG_TAG, "screen off (stale: screen is on again) -> ignored");
                return;
            }
            if (root.stopVoiceForScreenOff()) {
                Log.i(SideButtonGesture.LOG_TAG, "screen off -> voice stopped");
            }
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        SystemSetupState.markComplete(this);
        RuntimeService.start(this);
        runtimeHealth = new RuntimeHealthClient();
        runtimeManagement = new RuntimeManagementClient();
        backgroundRuns = new RuntimeBackgroundRunClient();
        creationImports = new RuntimeCreationImportClient();
        runtimeHealth.checkUntilReady(this, health -> {
            android.util.Log.i("SamRuntime", "HOME boundary status=" + health.status());
            if (sideButtonStartPending && root != null) {
                sideButtonStartPending = false;
                boolean started = root.startVoiceFromSideButton();
                Log.i(SideButtonGesture.LOG_TAG, "double press (cold start) -> "
                        + (started ? "voice started" : "already in session"));
            }
            if (noteAfterRuntime && root != null) {
                noteAfterRuntime = false;
                onVoiceNoteGesture("hold");
            }
        });
        setShowWhenLocked(true);
        setTurnScreenOn(true);
        root = new ProductRootView(
                this,
                this::confirmRestart,
                callback -> runtimeManagement.loadPairing(
                        this,
                        pairing -> callback.accept(
                                new ManagementPairingState(
                                        pairing.status(),
                                        pairing.code(),
                                        pairing.address(),
                                        pairing.expiresAt())
                        )
                ),
                runtimeManagement,
                backgroundRuns,
                creationImports);
        setContentView(root);
        current = new java.lang.ref.WeakReference<>(this);
        openT3ThreadFrom(getIntent(), state == null);
        openGeneratedUiFrom(getIntent(), state == null);
        // A fresh launch whose intent is the alias = double press while HOME was not running.
        // (A recreated activity keeps the old intent; it must not toggle again.)
        if (state == null && SideButtonGesture.isToggle(getIntent())) sideButtonStartPending = true;
        if (state == null && SideButtonGesture.isVoiceNote(getIntent())) noteAfterRuntime = true;
        SideButtonGesture.checkFrameworkPolicy(this);
        SideButtonSetting.addListener(sideButtonChanged);
        getContentResolver().registerContentObserver(
                Settings.Global.getUriFor(SideButtonGesture.THEATER_SETTING), false, theater);
        theaterRegistered = true;
        registerReceiver(screenOff, new IntentFilter(Intent.ACTION_SCREEN_OFF),
                Context.RECEIVER_NOT_EXPORTED);
        registerReceiver(screenOn, new IntentFilter(Intent.ACTION_SCREEN_ON), Context.RECEIVER_NOT_EXPORTED);
        screenOffRegistered = true;
        java.util.ArrayList<String> missing = new java.util.ArrayList<>();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.RECORD_AUDIO);
        }
        // "T3 updates" notifications (announcements that arrive while Voice is not live).
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            missing.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        if (!missing.isEmpty()) requestPermissions(missing.toArray(new String[0]), 41);
        // Android 16 routes Back through OnBackInvokedDispatcher; without this the HOME
        // activity is finished and recreated, dropping the user back on Voice.
        getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                () -> { if (root != null) root.navigateBack(); });
        NotificationFeed.ensureEnabled(this);
        disableSystemShade();
        DisplayPolicy.apply(getWindow());
        idle = new IdleScreenPolicy(this, getWindow(), root::screenBusy);
        root.setBusyListener(idle::onBusyChanged);
        idle.start();
        installFullscreenPolicy();
        enterProductFullscreen();
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (SideButtonGesture.isToggle(intent)) onSideButtonDoublePress();
        else if (SideButtonGesture.isVoiceNote(intent)) onVoiceNoteGesture("hold");
        else {
            openT3ThreadFrom(intent, true);
            openGeneratedUiFrom(intent, true);
        }
    }

    /** A tapped "Generated UIs" notification: Voice with that picture full screen. */
    private void openGeneratedUiFrom(Intent intent, boolean fresh) {
        if (!fresh || intent == null || root == null) return;
        String artifactId = intent.getStringExtra(GeneratedUiNotifier.EXTRA_ARTIFACT);
        if (artifactId == null) return;
        intent.removeExtra(GeneratedUiNotifier.EXTRA_ARTIFACT); // a recreated activity must not reopen it
        root.post(() -> root.openGeneratedUi(artifactId));
    }

    /** A tapped "T3 updates" notification: open that thread in the T3 tab. */
    private void openT3ThreadFrom(Intent intent, boolean fresh) {
        if (!fresh || intent == null || root == null) return;
        String threadId = intent.getStringExtra(T3UpdateNotifier.EXTRA_THREAD);
        if (threadId == null || threadId.isBlank()) return;
        intent.removeExtra(T3UpdateNotifier.EXTRA_THREAD); // a recreated activity must not reopen it
        Log.i("SamAnnounce", "notification tap -> open T3 thread");
        root.post(() -> root.openT3ThreadById(threadId));
    }

    /** Debug entry points only (src/debug); null when HOME is not running. */
    static ProductRootView activeRoot() {
        MainActivity activity = current.get();
        return activity == null || activity.isDestroyed() ? null : activity.root;
    }

    private void onSideButtonDoublePress() {
        if (root == null) return;
        if (idle != null) idle.onInteraction();
        if (!sideButton.accept(SystemClock.elapsedRealtime())) {
            Log.i(SideButtonGesture.LOG_TAG, "double press ignored (duplicate delivery)");
            return;
        }
        if (root.voiceNoteRecording()) {
            // A voice note is recording: any side-button gesture finishes and sends it. (One that is
            // already finishing or sending goes on off screen and this press talks: see
            // ProductRootView.toggleVoiceFromSideButton.)
            sideButtonStartPending = false;
            root.post(() -> {
                boolean sent = root.finishVoiceNote();
                Log.i(SideButtonGesture.LOG_TAG, "double press -> " + (sent ? "voice note sent" : "voice note busy"));
            });
            return;
        }
        // A newer gesture supersedes a cold-start "start" still waiting for the runtime health
        // check; otherwise start+stop presses in that window would be followed by a late start.
        sideButtonStartPending = false;
        // Posted so it runs after the resume that accompanies this intent: the microphone is
        // then opened from a TOP process (the press may have just woken the screen).
        root.post(() -> {
            boolean started = root.toggleVoiceFromSideButton();
            Log.i(SideButtonGesture.LOG_TAG, "double press -> " + (started ? "voice started" : "voice stopped"));
        });
    }

    /**
     * Triple press (theater flip) or hold (VOICE_ASSIST): start a voice note, or finish the one
     * recording. The microphone must be opened from a TOP process: when HOME is not resumed yet
     * (the press that woke the screen, another app in front) it waits for onResume.
     */
    private void onVoiceNoteGesture(String trigger) {
        if (root == null) return;
        if (idle != null) idle.onInteraction();
        if (!sideButton.acceptNote(SystemClock.elapsedRealtime())) {
            Log.i(SideButtonGesture.LOG_TAG, trigger + " ignored (duplicate delivery)");
            return;
        }
        if (!resumed) {
            voiceNotePending = trigger;
            voiceNotePendingAt = SystemClock.elapsedRealtime();
            Log.i(SideButtonGesture.LOG_TAG, trigger + " -> voice note when HOME is in front");
            try {
                startActivity(new Intent(this, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
            } catch (RuntimeException error) {
                Log.w(SideButtonGesture.LOG_TAG, "could not bring HOME to front: " + error.getClass().getSimpleName());
            }
            return;
        }
        root.post(() -> {
            boolean started = root.voiceNoteFromSideButton(trigger);
            Log.i(SideButtonGesture.LOG_TAG, trigger + " -> " + (started ? "voice note" : "voice note sent"));
        });
    }

    @Override protected void onDestroy() {
        if (current.get() == this) current = new java.lang.ref.WeakReference<>(null);
        SideButtonSetting.removeListener(sideButtonChanged);
        if (theaterRegistered) {
            getContentResolver().unregisterContentObserver(theater);
            theaterRegistered = false;
        }
        if (idle != null) idle.close();
        if (screenOffRegistered) {
            unregisterReceiver(screenOff);
            unregisterReceiver(screenOn);
            screenOffRegistered = false;
        }
        if (root != null) root.close();
        if (runtimeHealth != null) runtimeHealth.close();
        if (runtimeManagement != null) runtimeManagement.close();
        if (backgroundRuns != null) backgroundRuns.close();
        if (creationImports != null) creationImports.close();
        super.onDestroy();
    }

    private void confirmRestart() {
        new AlertDialog.Builder(this)
                .setTitle("Restart R1?")
                .setMessage("SamRabbit will restart and return to HOME.")
                .setNegativeButton("Cancel", null)
                .setPositiveButton("Restart", (ignored, which) -> {
                    PowerManager power = getSystemService(PowerManager.class);
                    if (power != null) power.reboot("sam-settings");
                })
                .show();
    }

    @Override protected void onResume() {
        super.onResume();
        resumed = true;
        DisplayPolicy.applyInputPolicy(getWindow());
        if (idle != null) idle.onResume();
        enterProductFullscreen();
        String pending = voiceNotePending;
        voiceNotePending = null;
        if (pending != null && SystemClock.elapsedRealtime() - voiceNotePendingAt > NOTE_PENDING_MAX_MS) {
            Log.i(SideButtonGesture.LOG_TAG, pending + " dropped (HOME came to the front too late)");
            pending = null;
        }
        if (pending != null && root != null) {
            String trigger = pending;
            root.post(() -> {
                boolean started = root.voiceNoteFromSideButton(trigger);
                Log.i(SideButtonGesture.LOG_TAG, trigger + " (after resume) -> "
                        + (started ? "voice note" : "voice note sent"));
            });
        }
    }

    @Override protected void onPause() {
        resumed = false;
        super.onPause();
    }

    /** Touch, keys and generic motion that reach the activity (the idle clock's interactions). */
    @Override public void onUserInteraction() {
        super.onUserInteraction();
        if (idle != null) idle.onInteraction();
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused) {
            DisplayPolicy.applyInputPolicy(getWindow());
            enterProductFullscreen();
        }
    }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        // The wheel and keys handled here skip super (and its onUserInteraction): count them first.
        if (idle != null && event.getAction() == KeyEvent.ACTION_DOWN) idle.onInteraction();
        if (root != null && root.onHardwareKey(event)) return true;
        return super.dispatchKeyEvent(event);
    }

    @Override public boolean onGenericMotionEvent(MotionEvent event) {
        if (root != null && root.onHardwareMotion(event)) return true;
        return super.onGenericMotionEvent(event);
    }

    @Override
    @SuppressLint("GestureBackNavigation")
    public void onBackPressed() {
        if (root != null) root.navigateBack();
    }

    private void enterProductFullscreen() {
        getWindow().setDecorFitsSystemWindows(false);
        WindowInsetsController controller = getWindow().getInsetsController();
        if (controller != null) {
            controller.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
            controller.setSystemBarsBehavior(
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        | View.SYSTEM_UI_FLAG_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    }

    /** The stock shade is unusable at 480x640; the HOME Control Center replaces it. */
    private void disableSystemShade() {
        try {
            Object statusBar = getSystemService("statusbar");
            int disableExpand = 0x00010000;
            statusBar.getClass().getMethod("disable", int.class).invoke(statusBar, disableExpand);
        } catch (ReflectiveOperationException | RuntimeException error) {
            android.util.Log.w("SamChrome", "system shade stays enabled: " + (error.getCause() != null ? error.getCause() : error));
        }
    }

    private void installFullscreenPolicy() {
        View decor = getWindow().getDecorView();
        decor.setOnApplyWindowInsetsListener((view, insets) -> {
            int bars = WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars();
            if (insets.isVisible(WindowInsets.Type.statusBars()) && root != null) {
                // A swipe from the top edge revealed the system bar: answer with our Control Center.
                view.post(root::openControlCenter);
            }
            if (insets.isVisible(bars)) view.post(this::enterProductFullscreen);
            return insets;
        });
        decor.setOnSystemUiVisibilityChangeListener(visibility -> {
            int hidden = View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION;
            if ((visibility & hidden) != hidden) decor.post(this::enterProductFullscreen);
        });
    }
}
