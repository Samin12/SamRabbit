package com.resonolabs.feature.settings;

import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import android.graphics.RadialGradient;
import android.graphics.RectF;
import android.graphics.Shader;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiManager;
import android.net.wifi.WifiConfiguration;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.WindowManager;
import android.widget.OverScroller;

import com.resonolabs.feature.compose.ComposeSheet;
import com.resonolabs.ui.design.FluidOrb;
import com.resonolabs.ui.design.GlassPainter;
import com.resonolabs.ui.design.OrbStyle;
import com.resonolabs.ui.design.OrbStyleSetting;
import com.resonolabs.ui.design.SamTheme;
import com.resonolabs.ui.input.UiInputIntent;
import com.resonolabs.ui.input.UiInputTarget;
import com.resonolabs.runtime.host.ManagementOpenAiSource;
import com.resonolabs.runtime.host.ManagementOpenAiState;
import com.resonolabs.ui.power.AlwaysOnVoice;
import com.resonolabs.ui.power.IdleScreenSetting;
import com.resonolabs.ui.power.SideButtonSetting;

import java.util.List;

/** Large-format settings designed for direct use on the 480x640 R1 display. */
public final class SettingsPanelView extends View implements UiInputTarget {
    private static final float DESIGN_WIDTH = 480f;
    private static final float DESIGN_HEIGHT = 640f;
    private static final float AI_PROVIDER_TOP = 100f;
    private static final float AI_PROVIDER_BOTTOM = 180f;
    private static final float AI_ACCESS_TOP = 196f;
    private static final float AI_ACCESS_BOTTOM = 275f;
    private static final float AI_VOICE_MODEL_TOP = 292f;
    private static final float AI_VOICE_MODEL_BOTTOM = 370f;
    private static final float AI_TEXT_MODEL_TOP = 386f;
    private static final float AI_TEXT_MODEL_BOTTOM = 464f;
    private static final float AI_REASONING_TOP = 480f;
    private static final float AI_REASONING_BOTTOM = 540f;
    private static final float AI_REFRESH_TOP = 556f;
    /** Sound page: the "Always-on voice" switch row between the volume hero and -/+. */
    private static final float ALWAYS_ON_TOP = 396f;
    private static final float ALWAYS_ON_BOTTOM = 472f;
    static final String THEME = "Theme";
    static final String SIDE_BUTTON = "Side button";
    /**
     * Theme sits right under the two radios: the first personal setting, high enough to be seen
     * without scrolling. Nine rows overflow 640 px, so the list scrolls (SettingsListLayout).
     */
    static final List<String> ROWS = List.of(
            "Wi-Fi", "Bluetooth", THEME, "Management", "AI", "Creations", "Sound", SIDE_BUTTON, "Display", "About");
    /** Drag distance (design px) before a touch on the list scrolls instead of tapping. */
    private static final float TOUCH_SLOP = 10f;
    /** Rows fade out over this many px where they slide under the header / off the bottom. */
    private static final float FADE_TOP = 20f;
    private static final float FADE_BOTTOM = 20f;
    // Display page: brightness (value, bar, -/+) and a link row to Settings > Theme.
    private static final RectF DISPLAY_BRIGHTNESS = new RectF(20f, 100f, 460f, 250f);
    private static final RectF DISPLAY_MINUS = new RectF(20f, 262f, 230f, 326f);
    private static final RectF DISPLAY_PLUS = new RectF(250f, 262f, 460f, 326f);
    private static final RectF DISPLAY_THEME_LINK = new RectF(20f, 342f, 460f, 406f);
    /** Display page: "Screen off · After 10 min / Never" (the HOME idle timeout). */
    private static final RectF DISPLAY_SCREEN_OFF = new RectF(20f, 422f, 460f, 498f);
    // Side button page: the talk line, then the three voice-note choices.
    private static final float SIDE_TALK_TOP = 100f;
    private static final float SIDE_OPTION_TOP = 214f;
    private static final float SIDE_OPTION_HEIGHT = 74f;
    private static final float SIDE_OPTION_GAP = 10f;
    private static final String[] SIDE_OPTION_LINES = {
            "Three quick presses", "Hold half a second · power menu at 3.5 s", "Triple press or hold"};
    // Theme page copy, per OrbStyle.values() (built once: the page redraws every frame).
    private static final String[] THEME_NAMES = new String[ThemePageLayout.TILES];
    private static final String[] THEME_APPLIED = new String[ThemePageLayout.TILES];
    private static final String[] THEME_LINES = {"Fluid blue sphere", "Retro voxel head"};
    static {
        for (OrbStyle style : OrbStyle.values()) {
            THEME_NAMES[style.ordinal()] = style.label();
            THEME_APPLIED[style.ordinal()] = style.label() + " applied";
        }
    }
    /** Dark "screen" behind each Theme preview, like the Voice page it stands for. */
    private static final int STAGE_FILL = 0xE106080C;   // argb(225, 6, 8, 12), a literal so unit tests can load the class
    private static final RectF BACK_DISC = new RectF(10f, 22f, 54f, 66f);
    private static final RectF CLOSE_DISC = new RectF(414f, 20f, 462f, 68f);

    private final Activity activity;
    private final Runnable close;
    private final Runnable restart;
    private final Runnable openCreationImport;
    private final ManagementPairingSource managementPairing;
    private final ManagementOpenAiSource openAiSource;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final FluidOrb aboutOrb = new FluidOrb().hero(getContext());
    /** Theme previews: a plain orb is always fluid; the head one is pinned while the page shows. */
    private final FluidOrb themeOrb = new FluidOrb().setColor(SamTheme.ORB_BLUE).setSpeed(0.6f);
    private final FluidOrb themeHead = new FluidOrb().setColor(SamTheme.ORB_BLUE).setSpeed(0.6f);
    private final RadialGradient[] stageGlows = new RadialGradient[ThemePageLayout.TILES];
    private final int[] stageGlowColors = new int[ThemePageLayout.TILES];
    private final GlassPainter glassPainter = new GlassPainter();
    /** Erases list rows toward the viewport edges (DST_OUT, unit-height gradient, opaque at y=0). */
    private final Paint edgeFade = new Paint();
    private final Path glyph = new Path();
    private final OverScroller scroller;
    private VelocityTracker velocity;
    /** List scroll (design px): where it is and where the wheel's glide is heading. */
    private float scroll;
    private float scrollTarget;
    private float downX;
    private float downY;
    private float lastY;
    private boolean dragging;
    /** The touch stopped a moving list, so lifting it is not also a tap. */
    private boolean caughtMotion;
    private int themeFocus;
    /** Side button page: the wheel's choice (applied with a tap or ACTIVATE). */
    private int sideFocus;
    private OrbStyle themeApplied = OrbStyle.FLUID;
    private long themeAppliedAt = -1L;
    /** Page that BACK returns to from Theme ("Display" when its link opened it), else the list. */
    private String themeReturn;
    private boolean onScreen;
    /**
     * The one pending animation frame (Theme previews, About orb, Display re-read). Re-posted
     * from onDraw after removing any earlier one: every input invalidate() also draws, and a
     * postInvalidateDelayed per draw would start another self-sustaining chain each time, so
     * a few taps on Theme took it from ~30 to the full 60 fps.
     */
    private final Runnable frameTick = this::invalidate;
    /** About's rows, read when the page opens (it animates; no per-frame PackageManager calls). */
    private SettingValue[] aboutValues;
    private final RectF buttonRect = new RectF();
    private final android.graphics.Typeface medium =
            android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL);
    private final LinearGradient brightnessFill = new LinearGradient(64f, 0f, 416f, 0f,
            SamTheme.ORB_PALE, SamTheme.ORB_BLUE, Shader.TileMode.CLAMP);
    private float displayLevel;
    private String displayValue;
    private int displayBrightness = -1;
    private long displayReadAt;
    private final WifiNetworkScanner wifiScanner;
    private int selected;
    private String openPage;
    private String wifiScanState = "Tap refresh to scan";
    private List<WifiNetworkScanner.Network> wifiNetworks = List.of();
    private String bluetoothStatus = "Ready";
    private ManagementPairingState managementState = ManagementPairingState.loading();
    private ManagementOpenAiState openAiState = ManagementOpenAiState.loading();
    private String openAiMessage = "";
    private String draftProvider = "openai";
    private String draftAccessPath = "platform";
    private String draftTextModel;
    private String draftRealtimeModel;
    private String draftReasoning = "none";
    private boolean aiDraftDirty;
    private boolean bluetoothReceiverRegistered;
    private final BroadcastReceiver bluetoothReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (intent == null || !BluetoothAdapter.ACTION_STATE_CHANGED.equals(intent.getAction())) return;
            int state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);
            bluetoothStatus = bluetoothStateLabel(state);
            invalidate();
        }
    };

    public SettingsPanelView(
            Activity activity,
            Runnable close,
            Runnable restart,
            Runnable openCreationImport,
            ManagementPairingSource managementPairing,
            ManagementOpenAiSource openAiSource) {
        super(activity);
        this.activity = activity;
        this.close = close;
        this.restart = restart;
        this.openCreationImport = openCreationImport;
        this.managementPairing = managementPairing;
        this.openAiSource = openAiSource;
        this.scroller = new OverScroller(activity);
        edgeFade.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_OUT));
        edgeFade.setShader(new LinearGradient(0f, 0f, 0f, 1f, Color.BLACK, Color.TRANSPARENT,
                Shader.TileMode.CLAMP));
        setFocusable(true);
        // Take focus even in touch mode: the R1 wheel sends key events, which leave touch mode,
        // and focus parked on the full-screen HOME root would draw the framework focus highlight
        // over everything (a grey wash). Settings draws its own focus.
        setFocusableInTouchMode(true);
        setDefaultFocusHighlightEnabled(false);
        this.wifiScanner = new WifiNetworkScanner(activity, (state, networks) -> {
            wifiScanState = state;
            wifiNetworks = List.copyOf(networks);
            invalidate();
        });
        setContentDescription("In-app device settings");
    }

    @Override protected void onDraw(Canvas canvas) {
        boolean moving = openPage == null && stepScroll();
        canvas.save();
        canvas.scale(getWidth() / DESIGN_WIDTH, getHeight() / DESIGN_HEIGHT);
        boolean about = "About".equals(openPage);
        boolean theme = THEME.equals(openPage);
        if (about) SamTheme.background(canvas, paint, DESIGN_WIDTH, DESIGN_HEIGHT,
                240f, 168f, 230f, SamTheme.ORB_BLUE);
        else SamTheme.background(canvas, paint, DESIGN_WIDTH, DESIGN_HEIGHT,
                90f, 20f, 300f, SamTheme.ORB_BLUE);
        if (openPage == null) drawIndex(canvas); else drawPage(canvas);
        canvas.restore();
        removeCallbacks(frameTick);
        if (!isShown()) return;
        // The list glides at vsync while it scrolls; the About orb and the Theme previews animate
        // at ~30 fps; Display re-reads the brightness twice a second; other pages are static.
        if (moving) postInvalidateOnAnimation();
        else if (about || theme) postDelayed(frameTick, 33L);
        else if ("Display".equals(openPage)) postDelayed(frameTick, 500L);
    }

    /** Moves the list one frame along a fling or the wheel's glide; true while it still moves. */
    private boolean stepScroll() {
        int rows = ROWS.size();
        if (scroller.computeScrollOffset()) {
            scroll = SettingsListLayout.clamp(scroller.getCurrY(), rows);
            scrollTarget = scroll;
            return true;
        }
        scrollTarget = SettingsListLayout.clamp(scrollTarget, rows);
        if (Math.abs(scrollTarget - scroll) > 0.5f) {
            scroll += (scrollTarget - scroll) * 0.3f;
            return true;
        }
        scroll = scrollTarget;
        return false;
    }

    /** Scrolls so the focused row is fully on screen (gliding, or at once when coming back). */
    private void revealSelected(boolean glide) {
        scroller.forceFinished(true);
        scrollTarget = SettingsListLayout.reveal(selected, scrollTarget, ROWS.size());
        if (!glide) scroll = scrollTarget;
    }

    private void drawIndex(Canvas canvas) {
        int rows = ROWS.size();
        float max = SettingsListLayout.maxScroll(rows);
        boolean above = scroll > 0.5f;
        boolean below = scroll < max - 0.5f;
        // Rows scroll under the fixed header; the first and last rows clamp (no overscroll). Where
        // rows are cut off they fade into whatever is behind them (an offscreen layer only then).
        int layer = above || below
                ? canvas.saveLayer(0f, SettingsListLayout.VIEW_TOP, DESIGN_WIDTH, DESIGN_HEIGHT, null)
                : canvas.save();
        canvas.clipRect(0f, SettingsListLayout.VIEW_TOP, DESIGN_WIDTH, DESIGN_HEIGHT);
        for (int i = 0; i < rows; i++) {
            float top = SettingsListLayout.rowTop(i, scroll);
            if (top > DESIGN_HEIGHT || top + SettingsListLayout.ROW_HEIGHT < SettingsListLayout.VIEW_TOP) continue;
            drawIndexRow(canvas, i, top);
        }
        if (above) fadeEdge(canvas, SettingsListLayout.VIEW_TOP, FADE_TOP);
        if (below) fadeEdge(canvas, DESIGN_HEIGHT, -FADE_BOTTOM);
        canvas.restoreToCount(layer);
        SamTheme.text(canvas, paint, "Settings", 24f, 56f, 34f,
                SamTheme.INK, Paint.Align.LEFT, true);
        drawClose(canvas);
    }

    /** Erases rows from {@code edge} fading over {@code length} px (negative = upward). */
    private void fadeEdge(Canvas canvas, float edge, float length) {
        canvas.save();
        canvas.translate(0f, edge);
        canvas.scale(1f, length);
        canvas.drawRect(0f, 0f, DESIGN_WIDTH, 1f, edgeFade);
        canvas.restore();
    }

    /** One list row; allocation-free (the list redraws every frame while it scrolls). */
    private void drawIndexRow(Canvas canvas, int index, float top) {
        String name = ROWS.get(index);
        boolean focused = index == selected;
        float h = SettingsListLayout.ROW_HEIGHT;
        float mid = top + h / 2f;
        glassPainter.draw(canvas, paint, 20f, top, 460f, top + h, 20f, focused);
        if (focused) {
            // Fixed-size accent only, so the focus cue never changes overall
            // row luminance enough to drive the panel's backlight compensation.
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(SamTheme.ORB_BLUE);
            canvas.drawRoundRect(20f, mid - 13f, 24f, mid + 13f, 2f, 2f, paint);
        }
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.ORB_BLUE, focused ? 70 : 42));
        canvas.drawCircle(56f, mid, 18f, paint);
        drawRowIcon(canvas, name, 56f, mid);
        SamTheme.text(canvas, paint, name, 88f, top + 37f, 22f,
                SamTheme.INK, Paint.Align.LEFT, true);
        if (THEME.equals(name)) {
            SamTheme.text(canvas, paint, OrbStyleSetting.current().label(), 418f, top + 36f, 18f,
                    focused ? SamTheme.ORB_PALE : SamTheme.MUTED, Paint.Align.RIGHT, false);
        } else if (SIDE_BUTTON.equals(name)) {
            SamTheme.text(canvas, paint, SideButtonSetting.voiceNote(activity).label, 418f, top + 36f, 18f,
                    focused ? SamTheme.ORB_PALE : SamTheme.MUTED, Paint.Align.RIGHT, false);
        }
        chevron(canvas, 436f, mid, focused ? SamTheme.ORB_PALE : SamTheme.MUTED);
    }

    private void drawPage(Canvas canvas) {
        drawBack(canvas);
        SamTheme.text(canvas, paint, openPage, 66f, 54f, 30f,
                SamTheme.INK, Paint.Align.LEFT, true);
        drawClose(canvas);

        switch (openPage) {
            case "Wi-Fi" -> drawWifiPage(canvas);
            case "Management" -> drawManagementPage(canvas);
            case "AI" -> drawAiPage(canvas);
            case "Sound" -> drawSoundPage(canvas);
            case "Display" -> drawDisplayPage(canvas);
            case SIDE_BUTTON -> drawSideButtonPage(canvas);
            case THEME -> drawThemePage(canvas);
            case "Bluetooth" -> drawBluetoothPage(canvas);
            case "About" -> drawAboutPage(canvas);
            default -> {
                drawInfoGroup(canvas, sentenceLabels(statusValues(openPage)), 108f);
                button(canvas, "Refresh", 20f, 494f, 460f);
            }
        }
    }

    private void drawSoundPage(Canvas canvas) {
        AudioManager audio = activity.getSystemService(AudioManager.class);
        int current = audio == null ? 0 : audio.getStreamVolume(AudioManager.STREAM_MUSIC);
        int max = audio == null ? 0 : audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        float level = max == 0 ? 0f : current / (float) max;
        drawLevelHero(canvas, "Volume", sound()[0].value, level);
        drawAlwaysOnRow(canvas);
        stepButtons(canvas);
    }

    /** The open sub-page ("Sound", "AI", ...) or null on the list (debug state for test scripts). */
    public String openPageName() {
        return openPage;
    }

    /** Always-on voice: keep a voice session listening with the screen off, reconnect if it drops. */
    private void drawAlwaysOnRow(Canvas canvas) {
        boolean on = AlwaysOnVoice.isEnabled(activity);
        RectF row = new RectF(20f, ALWAYS_ON_TOP, 460f, ALWAYS_ON_BOTTOM);
        SamTheme.glass(canvas, paint, row, 22f, false);
        SamTheme.text(canvas, paint, "Always-on voice", 40f, ALWAYS_ON_TOP + 33f, 20f,
                SamTheme.INK, Paint.Align.LEFT, true);
        SamTheme.text(canvas, paint, on ? "Keeps listening with the screen off" : "Screen off ends the session",
                40f, ALWAYS_ON_TOP + 58f, 14f, SamTheme.MUTED, Paint.Align.LEFT, false);
        float cy = (ALWAYS_ON_TOP + ALWAYS_ON_BOTTOM) / 2f;
        RectF track = new RectF(374f, cy - 17f, 436f, cy + 17f);
        if (on) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(SamTheme.ORB_BLUE);
            canvas.drawRoundRect(track, 17f, 17f, paint);
        } else {
            SamTheme.glass(canvas, paint, track, 17f, false);
        }
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(on ? SamTheme.INK : SamTheme.MUTED);
        canvas.drawCircle(on ? 419f : 391f, cy, 13f, paint);
    }

    private void drawDisplayPage(Canvas canvas) {
        // Redrawn twice a second, so nothing here allocates: the brightness is re-read because
        // the Control Center can change it over this page.
        long now = SystemClock.uptimeMillis();
        if (displayValue == null || now >= displayReadAt) readDisplayBrightness(now);
        glassPainter.draw(canvas, paint, DISPLAY_BRIGHTNESS, 24f, false);
        SamTheme.text(canvas, paint, "Brightness", 240f, 134f, 16f, SamTheme.MUTED, Paint.Align.CENTER, false);
        SamTheme.text(canvas, paint, displayValue, 240f, 196f, 54f, SamTheme.INK, Paint.Align.CENTER, true);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.INK, 26));
        canvas.drawRoundRect(64f, 220f, 416f, 229f, 4.5f, 4.5f, paint);
        if (displayLevel > 0f) {
            paint.setColor(SamTheme.INK);
            paint.setShader(brightnessFill);
            canvas.drawRoundRect(64f, 220f, 64f + 352f * displayLevel, 229f, 4.5f, 4.5f, paint);
            paint.setShader(null);
            canvas.drawCircle(64f + 352f * displayLevel, 224.5f, 9f, paint);
        }
        glassPainter.draw(canvas, paint, DISPLAY_MINUS, 24f, false);
        glassPainter.draw(canvas, paint, DISPLAY_PLUS, 24f, false);
        SamTheme.text(canvas, paint, "−", DISPLAY_MINUS.centerX(), DISPLAY_MINUS.centerY() + 12f, 38f,
                SamTheme.INK, Paint.Align.CENTER, true);
        SamTheme.text(canvas, paint, "+", DISPLAY_PLUS.centerX(), DISPLAY_PLUS.centerY() + 12f, 38f,
                SamTheme.INK, Paint.Align.CENTER, true);
        drawThemeLink(canvas);
        drawScreenOffRow(canvas);
        SamTheme.text(canvas, paint, IdleScreenSetting.never(activity) ? "The screen stays on while SamRabbit is open"
                        : "Off after 10 min with nothing going on · any press wakes it", 240f, 600f, 15f,
                SamTheme.MUTED, Paint.Align.CENTER, false);
    }

    /** "Screen off   After 10 min" with a switch (on = turns off when idle, the default). */
    private void drawScreenOffRow(Canvas canvas) {
        RectF row = DISPLAY_SCREEN_OFF;
        boolean idleOff = !IdleScreenSetting.never(activity);
        glassPainter.draw(canvas, paint, row, 22f, false);
        SamTheme.text(canvas, paint, "Screen off", 40f, row.top + 33f, 20f, SamTheme.INK, Paint.Align.LEFT, true);
        SamTheme.text(canvas, paint, idleOff ? "After 10 min" : "Never", 40f, row.top + 58f, 14f, SamTheme.MUTED,
                Paint.Align.LEFT, false);
        drawSwitch(canvas, row.centerY(), idleOff);
    }

    /** The pill switch at the right of a row (allocation-free). */
    private void drawSwitch(Canvas canvas, float cy, boolean on) {
        if (on) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(SamTheme.ORB_BLUE);
            canvas.drawRoundRect(374f, cy - 17f, 436f, cy + 17f, 17f, 17f, paint);
        } else {
            glassPainter.draw(canvas, paint, 374f, cy - 17f, 436f, cy + 17f, 17f, false);
        }
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(on ? SamTheme.INK : SamTheme.MUTED);
        canvas.drawCircle(on ? 419f : 391f, cy, 13f, paint);
    }

    /**
     * Settings &gt; Side button: double press talks (fixed); the voice note is a triple press, a hold
     * or both. Triple press needs the framework overlay that ships with SamRabbit (a restart after an
     * update): the status line says when it is not active yet. Allocation-free.
     */
    private void drawSideButtonPage(Canvas canvas) {
        glassPainter.draw(canvas, paint, 20f, SIDE_TALK_TOP, 460f, SIDE_TALK_TOP + 84f, 22f, false);
        SamTheme.text(canvas, paint, "Double-press", 40f, SIDE_TALK_TOP + 36f, 20f, SamTheme.INK, Paint.Align.LEFT, true);
        SamTheme.text(canvas, paint, "Talk: starts or ends a voice chat", 40f, SIDE_TALK_TOP + 62f, 15f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        paint.setLetterSpacing(0.14f);
        SamTheme.text(canvas, paint, "VOICE NOTE", 40f, SIDE_OPTION_TOP - 14f, 13f,
                SamTheme.withAlpha(SamTheme.INK, 190), Paint.Align.LEFT, true);
        paint.setLetterSpacing(0f);
        SideButtonSetting.VoiceNote current = SideButtonSetting.voiceNote(activity);
        SideButtonSetting.VoiceNote[] choices = SideButtonSetting.VoiceNote.values();
        for (int i = 0; i < choices.length; i++) {
            float top = SIDE_OPTION_TOP + i * (SIDE_OPTION_HEIGHT + SIDE_OPTION_GAP);
            boolean chosen = choices[i] == current;
            boolean focused = i == sideFocus;
            glassPainter.draw(canvas, paint, 20f, top, 460f, top + SIDE_OPTION_HEIGHT, 22f, focused);
            SamTheme.text(canvas, paint, choices[i].label, 40f, top + 33f, 20f, SamTheme.INK, Paint.Align.LEFT, true);
            SamTheme.text(canvas, paint, SIDE_OPTION_LINES[i], 40f, top + 57f, 14f, SamTheme.MUTED,
                    Paint.Align.LEFT, false);
            float cy = top + SIDE_OPTION_HEIGHT / 2f;
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2.4f);
            paint.setColor(chosen ? SamTheme.ORB_BLUE : SamTheme.withAlpha(SamTheme.MUTED, 200));
            canvas.drawCircle(420f, cy, 13f, paint);
            paint.setStyle(Paint.Style.FILL);
            if (chosen) {
                paint.setColor(SamTheme.ORB_BLUE);
                canvas.drawCircle(420f, cy, 7.5f, paint);
            }
        }
        String status;
        int color = SamTheme.MUTED;
        switch (current.triple() ? SideButtonSetting.tripleState() : SideButtonSetting.TripleState.UNKNOWN) {
            case READY -> status = "Triple press is on · presses 0.3 s apart";
            case NEEDS_RESTART -> { status = "Triple press works after the next restart"; color = SamTheme.AMBER; }
            case UNAVAILABLE -> { status = "Triple press isn't available on this R1"; color = SamTheme.AMBER; }
            default -> status = current.hold() ? "Hold the button until the note opens" : "";
        }
        float statusY = SIDE_OPTION_TOP + 3 * (SIDE_OPTION_HEIGHT + SIDE_OPTION_GAP) + 26f;
        if (!status.isEmpty()) {
            SamTheme.text(canvas, paint, status, 240f, statusY, 15f, color, Paint.Align.CENTER, false);
        }
        SamTheme.text(canvas, paint, "While recording: a press or a tap sends · Back cancels", 240f, 600f, 15f,
                SamTheme.MUTED, Paint.Align.CENTER, false);
    }

    private void chooseVoiceNote(int index) {
        SideButtonSetting.VoiceNote[] choices = SideButtonSetting.VoiceNote.values();
        sideFocus = Math.max(0, Math.min(choices.length - 1, index));
        SideButtonSetting.setVoiceNote(activity, choices[sideFocus]);
        invalidate();
    }

    /** One line under brightness pointing at the look's real home: "Theme   Pixel head ›". */
    private void drawThemeLink(Canvas canvas) {
        RectF row = DISPLAY_THEME_LINK;
        float mid = row.centerY();
        glassPainter.draw(canvas, paint, row, 22f, false);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.ORB_BLUE, 42));
        canvas.drawCircle(56f, mid, 18f, paint);
        drawRowIcon(canvas, THEME, 56f, mid);
        SamTheme.text(canvas, paint, THEME, 88f, mid + 8f, 21f, SamTheme.INK, Paint.Align.LEFT, true);
        SamTheme.text(canvas, paint, OrbStyleSetting.current().label(), 418f, mid + 7f, 18f,
                SamTheme.MUTED, Paint.Align.RIGHT, false);
        chevron(canvas, 436f, mid, SamTheme.MUTED);
    }

    /**
     * Settings > Theme: two live previews side by side, each drawn in its own style whatever is
     * applied. The applied one wears a bright outline and an "Applied" badge; the wheel's focus
     * lifts its tile's glass (and turns "Tap to apply" into a pill). Redrawn every frame (~30 fps)
     * for the previews, so nothing here allocates.
     */
    private void drawThemePage(Canvas canvas) {
        long now = SystemClock.uptimeMillis();
        themeHead.pinStyle(activity, OrbStyle.PIXEL_HEAD);   // idempotent; unpinned off this page
        OrbStyle applied = OrbStyleSetting.current();
        long sinceApplied = themeAppliedAt < 0L ? -1L : now - themeAppliedAt;
        for (int i = 0; i < ThemePageLayout.TILES; i++) {
            drawThemeTile(canvas, i, i == applied.ordinal(), i == themeFocus,
                    themeApplied.ordinal() == i ? sinceApplied : -1L);
        }
        float toast = ThemePageLayout.toastAlpha(sinceApplied);
        if (toast > 0f) {
            drawThemeToast(canvas, THEME_APPLIED[themeApplied.ordinal()], toast);
        } else {
            SamTheme.text(canvas, paint, "Shows everywhere the orb appears", 240f, 590f, 15f,
                    SamTheme.MUTED, Paint.Align.CENTER, false);
        }
    }

    private void drawThemeTile(Canvas canvas, int tile, boolean applied, boolean focused, long sinceApplied) {
        float left = ThemePageLayout.TILE_LEFT[tile];
        float right = ThemePageLayout.TILE_RIGHT[tile];
        float top = ThemePageLayout.TILE_TOP;
        float bottom = ThemePageLayout.TILE_BOTTOM;
        float cx = ThemePageLayout.tileCenterX(tile);
        glassPainter.draw(canvas, paint, left, top, right, bottom, 26f, focused);

        // The preview "screen": dark stage, the style's own page glow, then the live orb or head.
        float inset = ThemePageLayout.STAGE_INSET;
        float stageBottom = ThemePageLayout.STAGE_BOTTOM;
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(null);
        paint.setColor(STAGE_FILL);
        canvas.drawRoundRect(left + inset, top + inset, right - inset, stageBottom, 18f, 18f, paint);
        FluidOrb orb = tile == OrbStyle.PIXEL_HEAD.ordinal() ? themeHead : themeOrb;
        orb.setEnergy(focused ? 0.22f : 0.12f);
        float cy = ThemePageLayout.previewCenterY();
        float glowRadius = Math.min(right - left - 2f * inset, stageBottom - top - inset) / 2f - 2f;
        paint.setColor(Color.BLACK);
        paint.setShader(stageGlow(tile, orb.color()));
        canvas.save();
        canvas.translate(cx, cy);
        canvas.scale(glowRadius, glowRadius);
        canvas.drawCircle(0f, 0f, 1f, paint);
        canvas.restore();
        paint.setShader(null);
        orb.draw(canvas, cx, cy + orb.bob(3f), orb == themeHead
                ? ThemePageLayout.HEAD_PREVIEW_RADIUS : ThemePageLayout.PREVIEW_RADIUS);

        SamTheme.text(canvas, paint, THEME_NAMES[tile], cx, 410f, 24f, SamTheme.INK, Paint.Align.CENTER, true);
        SamTheme.text(canvas, paint, THEME_LINES[tile], cx, 436f, 15f, SamTheme.MUTED, Paint.Align.CENTER, false);
        if (applied) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(3f);
            paint.setColor(SamTheme.ORB_PALE);
            canvas.drawRoundRect(left + 1.5f, top + 1.5f, right - 1.5f, bottom - 1.5f, 25f, 25f, paint);
            paint.setStyle(Paint.Style.FILL);
            drawAppliedBadge(canvas, cx, 490f, ThemePageLayout.badgeScale(sinceApplied),
                    ThemePageLayout.badgeAlpha(sinceApplied));
        } else if (focused) {
            // The wheel's focus on a style that is not applied yet: a glass pill invites the tap.
            glassPainter.draw(canvas, paint, cx - 70f, 472f, cx + 70f, 508f, 18f, true);
            SamTheme.text(canvas, paint, "Tap to apply", cx, 496f, 16f, SamTheme.INK, Paint.Align.CENTER, true);
        } else {
            SamTheme.text(canvas, paint, "Tap to apply", cx, 496f, 16f, SamTheme.MUTED, Paint.Align.CENTER, false);
        }
    }

    /** Cached unit-radius page glow for a stage, rebuilt only when its colour changes. */
    private RadialGradient stageGlow(int tile, int color) {
        if (stageGlows[tile] == null || stageGlowColors[tile] != color) {
            stageGlowColors[tile] = color;
            stageGlows[tile] = new RadialGradient(0f, 0f, 1f, SamTheme.withAlpha(color, 84),
                    SamTheme.withAlpha(color, 0), Shader.TileMode.CLAMP);
        }
        return stageGlows[tile];
    }

    /** Solid "✓ Applied" pill; pops in (scale, fade) right after a style is applied. */
    private void drawAppliedBadge(Canvas canvas, float cx, float cy, float scale, float alpha) {
        int a = Math.round(255f * Math.max(0f, Math.min(1f, alpha)));
        canvas.save();
        canvas.scale(scale, scale, cx, cy);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.ORB_BLUE, Math.round(a * 0.94f)));
        canvas.drawRoundRect(cx - 62f, cy - 18f, cx + 62f, cy + 18f, 18f, 18f, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.6f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(SamTheme.withAlpha(SamTheme.INK, a));
        glyph.reset();
        glyph.moveTo(cx - 42f, cy);
        glyph.lineTo(cx - 36.5f, cy + 5.5f);
        glyph.lineTo(cx - 27f, cy - 5.5f);
        canvas.drawPath(glyph, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeJoin(Paint.Join.MITER);
        SamTheme.text(canvas, paint, "Applied", cx + 10f, cy + 6f, 17f,
                SamTheme.withAlpha(SamTheme.INK, a), Paint.Align.CENTER, true);
        canvas.restore();
    }

    /** "Pixel head applied": a small glass pill near the bottom that fades in and out. */
    private void drawThemeToast(Canvas canvas, String text, float alpha) {
        int a = Math.round(255f * alpha);
        // The pill hugs the text (measured in its own size and weight).
        paint.setTextSize(17f);
        paint.setTypeface(medium);
        float half = Math.max(80f, paint.measureText(text) / 2f + 32f);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.PANEL_RAISED, Math.round(a * 0.96f)));
        canvas.drawRoundRect(240f - half, 562f, 240f + half, 606f, 22f, 22f, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.2f);
        paint.setColor(SamTheme.withAlpha(SamTheme.ORB_PALE, Math.round(a * 0.5f)));
        canvas.drawRoundRect(240.6f - half, 562.6f, 239.4f + half, 605.4f, 22f, 22f, paint);
        paint.setStyle(Paint.Style.FILL);
        SamTheme.text(canvas, paint, text, 240f, 590f, 17f, SamTheme.withAlpha(SamTheme.INK, a),
                Paint.Align.CENTER, true);
    }

    private void readDisplayBrightness(long now) {
        displayReadAt = now + 500L;
        int brightness = Settings.System.getInt(activity.getContentResolver(),
                Settings.System.SCREEN_BRIGHTNESS, 0);
        if (displayValue != null && brightness == displayBrightness) return;
        displayBrightness = brightness;
        displayLevel = Math.max(0f, Math.min(1f, brightness / 255f));
        displayValue = Math.round(brightness * 100f / 255f) + "%";
    }

    /** Display page taps: brightness -/+, the link row that opens Theme and the Screen off switch. */
    private void onDisplayTap(float x, float y) {
        if (y >= DISPLAY_SCREEN_OFF.top - 6f && y <= DISPLAY_SCREEN_OFF.bottom + 6f) {
            IdleScreenSetting.setNever(activity, !IdleScreenSetting.never(activity));
        } else if (y >= DISPLAY_MINUS.top - 6f && y <= DISPLAY_MINUS.bottom + 6f) {
            adjustBrightness(x >= DESIGN_WIDTH / 2f);
            displayValue = null;
        } else if (y >= DISPLAY_THEME_LINK.top - 6f && y <= DISPLAY_THEME_LINK.bottom + 6f) {
            themeReturn = "Display";
            showPage(THEME);
            return;
        }
        invalidate();
    }

    /** Theme tile tapped or ACTIVATE: applies the style everywhere at once and confirms it. */
    private void applyTheme(OrbStyle style) {
        themeFocus = style.ordinal();
        if (OrbStyleSetting.current() != style) {
            OrbStyleSetting.set(activity, style);
            themeApplied = style;
            themeAppliedAt = SystemClock.uptimeMillis();
        }
        invalidate();
    }

    /**
     * Keeps the head preview pinned (its art decoded) only while the Theme page is on screen;
     * elsewhere it lets the art go when the user's style is the orb.
     */
    private void updateThemePin() {
        boolean showing = onScreen && THEME.equals(openPage);
        themeHead.pinStyle(activity, showing ? OrbStyle.PIXEL_HEAD : null);
    }

    @Override public void onVisibilityAggregated(boolean isVisible) {
        super.onVisibilityAggregated(isVisible);
        onScreen = isVisible;
        updateThemePin();
    }

    private void drawLevelHero(Canvas canvas, String label, String value, float level) {
        RectF panel = new RectF(20f, 108f, 460f, 380f);
        SamTheme.glass(canvas, paint, panel, 24f, false);
        SamTheme.text(canvas, paint, label, 240f, 160f, 18f,
                SamTheme.MUTED, Paint.Align.CENTER, false);
        SamTheme.text(canvas, paint, value, 240f, 262f, 80f,
                SamTheme.INK, Paint.Align.CENTER, true);
        float clamped = Math.max(0f, Math.min(1f, level));
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.INK, 26));
        canvas.drawRoundRect(64f, 316f, 416f, 326f, 5f, 5f, paint);
        if (clamped > 0f) {
            paint.setShader(new LinearGradient(64f, 0f, 416f, 0f, SamTheme.ORB_PALE,
                    SamTheme.ORB_BLUE, Shader.TileMode.CLAMP));
            canvas.drawRoundRect(64f, 316f, 64f + 352f * clamped, 326f, 5f, 5f, paint);
            paint.setShader(null);
            paint.setColor(SamTheme.INK);
            canvas.drawCircle(64f + 352f * clamped, 321f, 9f, paint);
        }
    }

    private void stepButtons(Canvas canvas) {
        button(canvas, "−", 20f, 494f, 230f);
        button(canvas, "+", 250f, 494f, 460f);
    }

    private void drawBluetoothPage(Canvas canvas) {
        boolean on = isBluetoothEnabled();
        RectF panel = new RectF(20f, 108f, 460f, 420f);
        SamTheme.glass(canvas, paint, panel, 24f, false);
        if (on) {
            orbDot(canvas, 240f, 210f, 42f);
        } else {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2f);
            paint.setColor(SamTheme.withAlpha(SamTheme.MUTED, 140));
            canvas.drawCircle(240f, 210f, 42f, paint);
            paint.setStyle(Paint.Style.FILL);
        }
        drawBluetoothGlyph(canvas, 240f, 210f, on ? 2.0f : 1.6f,
                on ? SamTheme.withAlpha(SamTheme.BACKGROUND, 200) : SamTheme.MUTED);
        SamTheme.text(canvas, paint, on ? "On" : "Off", 240f, 330f, 40f,
                SamTheme.INK, Paint.Align.CENTER, true);
        SamTheme.text(canvas, paint, bluetoothStatus, 240f, 368f, 18f,
                SamTheme.MUTED, Paint.Align.CENTER, false);
        if (on) button(canvas, "Turn off", 20f, 494f, 460f);
        else primaryButton(canvas, "Turn on", 20f, 494f, 460f);
    }

    private void drawAboutPage(Canvas canvas) {
        float orbY = 168f + aboutOrb.bob(4f);
        aboutOrb.setColor(SamTheme.ORB_BLUE).setEnergy(0.15f).setSpeed(0.6f);
        aboutOrb.draw(canvas, 240f, orbY, 50f);
        if (aboutValues == null) aboutValues = sentenceLabels(statusValues("About"));
        drawInfoGroup(canvas, aboutValues, 258f);
        button(canvas, "Restart device", 20f, 494f, 460f);
        SamTheme.text(canvas, paint, "Orb design inspired by Rare UI · rareui.com", 240f, 606f,
                14f, SamTheme.MUTED, Paint.Align.CENTER, false);
    }

    /** The same rows with display labels ("DEVICE" becomes "Device"). */
    private static SettingValue[] sentenceLabels(SettingValue[] values) {
        SettingValue[] out = new SettingValue[values.length];
        for (int i = 0; i < values.length; i++) out[i] = new SettingValue(sentence(values[i].label), values[i].value);
        return out;
    }

    /** Grouped glass panel of label/value rows separated by hairlines; labels are drawn as given. */
    private void drawInfoGroup(Canvas canvas, SettingValue[] values, float top) {
        float rowHeight = 64f;
        glassPainter.draw(canvas, paint, 20f, top, 460f, top + values.length * rowHeight, 22f, false);
        for (int i = 0; i < values.length; i++) {
            float y = top + i * rowHeight;
            if (i > 0) {
                paint.setStyle(Paint.Style.FILL);
                paint.setColor(SamTheme.LINE);
                canvas.drawRect(40f, y, 440f, y + 1f, paint);
            }
            SamTheme.text(canvas, paint, values[i].label, 42f, y + 40f, 18f,
                    SamTheme.MUTED, Paint.Align.LEFT, false);
            paint.setTextSize(20f);
            paint.setTypeface(medium);
            SamTheme.text(canvas, paint, ellipsize(values[i].value, 250f), 438f, y + 40f, 20f,
                    SamTheme.INK, Paint.Align.RIGHT, true);
        }
    }

    private void drawWifiPage(Canvas canvas) {
        SettingValue[] values = network();
        String summary = "Wi-Fi " + values[0].value.toLowerCase()
                + " · " + ("Connected".equals(values[1].value) ? "Online" : "Offline");
        SamTheme.text(canvas, paint, summary, 67f, 80f, 15f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        String wifiHint = wifiNetworks.isEmpty() ? wifiScanState : "Tap a network to connect";
        SamTheme.text(canvas, paint, wifiHint, 24f, 130f, 16f,
                SamTheme.ORB_PALE, Paint.Align.LEFT, true);
        float top = 148f;
        int count = Math.min(6, wifiNetworks.size());
        for (int i = 0; i < count; i++) {
            WifiNetworkScanner.Network network = wifiNetworks.get(i);
            SamTheme.glass(canvas, paint, new RectF(20f, top, 460f, top + 52f), 18f,
                    network.connected());
            if (network.connected()) {
                paint.setColor(SamTheme.ORB_BLUE);
                canvas.drawCircle(40f, top + 26f, 5f, paint);
            }
            paint.setTextSize(20f);
            paint.setTypeface(android.graphics.Typeface.create("sans-serif-medium",
                    android.graphics.Typeface.NORMAL));
            SamTheme.text(canvas, paint, ellipsize(network.ssid(), 260f), 56f, top + 33f, 20f,
                    SamTheme.INK, Paint.Align.LEFT, true);
            String detail = network.connected() ? "Connected" : (network.secured() ? "Secured" : "Open");
            SamTheme.text(canvas, paint, detail, 414f, top + 32f, 14f,
                    network.connected() ? SamTheme.ORB_PALE : SamTheme.MUTED,
                    Paint.Align.RIGHT, false);
            for (int bar = 0; bar < 4; bar++) {
                paint.setColor(bar < network.signalLevel()
                        ? SamTheme.ORB_PALE : SamTheme.withAlpha(SamTheme.MUTED, 70));
                canvas.drawRoundRect(424f + bar * 7f, top + 36f - bar * 5f,
                        428f + bar * 7f, top + 40f, 2f, 2f, paint);
            }
            top += 59f;
        }
        button(canvas, "Scan again", 20f, 532f, 460f);
    }

    private void drawManagementPage(Canvas canvas) {
        RectF codePanel = new RectF(20f, 108f, 460f, 290f);
        SamTheme.glass(canvas, paint, codePanel, 24f, true);
        SamTheme.text(canvas, paint, "Pairing code", 240f, 152f, 18f,
                SamTheme.MUTED, Paint.Align.CENTER, false);
        paint.setLetterSpacing(0.12f);
        String code = managementState.code();
        float codeSize = 72f;
        paint.setTextSize(codeSize);
        while (codeSize > 36f && paint.measureText(code == null ? "" : code) > 400f) {
            codeSize -= 4f;
            paint.setTextSize(codeSize);
        }
        SamTheme.text(canvas, paint, code, 240f, 246f, codeSize,
                SamTheme.INK, Paint.Align.CENTER, true);
        paint.setLetterSpacing(0f);

        RectF addressPanel = new RectF(20f, 306f, 460f, 446f);
        SamTheme.glass(canvas, paint, addressPanel, 22f, false);
        SamTheme.text(canvas, paint, "Open on your computer", 42f, 344f, 16f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        paint.setTextSize(22f);
        paint.setTypeface(android.graphics.Typeface.create("sans-serif-medium",
                android.graphics.Typeface.NORMAL));
        SamTheme.text(canvas, paint, ellipsize(managementState.address(), 396f), 42f, 386f, 22f,
                SamTheme.ORB_PALE, Paint.Align.LEFT, true);
        SamTheme.text(canvas, paint, "Secure link · same Wi-Fi network", 42f, 420f, 15f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        button(canvas, "Refresh", 20f, 494f, 460f);
    }

    private void drawAiPage(Canvas canvas) {
        String status = openAiMessage == null || openAiMessage.isBlank()
                ? (openAiState.fallbackMessage() == null ? "" : openAiState.fallbackMessage())
                : openAiMessage;
        boolean connected = openAiState.connected() || openAiState.platformConnected()
                || openAiState.subscriptionConnected();
        if (status.isBlank()) status = connected ? "Connected" : "Not connected";
        int statusColor = openAiState.error() ? SamTheme.AMBER
                : aiDraftDirty ? SamTheme.ORB_PALE : SamTheme.MUTED;
        paint.setTextSize(15f);
        paint.setTypeface(android.graphics.Typeface.create("sans-serif",
                android.graphics.Typeface.NORMAL));
        SamTheme.text(canvas, paint, ellipsize(status, 320f), 67f, 82f, 15f,
                statusColor, Paint.Align.LEFT, false);

        aiRow(canvas, AI_PROVIDER_TOP, AI_PROVIDER_BOTTOM, "Provider", providerLabel(draftProvider),
                connected ? SamTheme.INK : SamTheme.MUTED);
        aiRow(canvas, AI_ACCESS_TOP, AI_ACCESS_BOTTOM, "Access", accessLabel(draftAccessPath),
                SamTheme.INK);
        aiRow(canvas, AI_VOICE_MODEL_TOP, AI_VOICE_MODEL_BOTTOM, "Voice model",
                draftRealtimeModel == null || draftRealtimeModel.isBlank() ? "—" : draftRealtimeModel,
                SamTheme.INK);
        aiRow(canvas, AI_TEXT_MODEL_TOP, AI_TEXT_MODEL_BOTTOM, "Text model",
                draftTextModel == null || draftTextModel.isBlank() ? "—" : draftTextModel,
                SamTheme.INK);

        // Reasoning row is shorter: label and value share one line.
        RectF reasoning = new RectF(20f, AI_REASONING_TOP, 460f, AI_REASONING_BOTTOM);
        SamTheme.glass(canvas, paint, reasoning, 20f, false);
        float mid = (AI_REASONING_TOP + AI_REASONING_BOTTOM) / 2f;
        SamTheme.text(canvas, paint, "Reasoning", 42f, mid + 7f, 18f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        SamTheme.text(canvas, paint, sentence(draftReasoning), 384f, mid + 8f, 21f,
                openAiState.error() ? SamTheme.AMBER : SamTheme.INK, Paint.Align.RIGHT, true);
        stepper(canvas, mid);

        if (aiDraftDirty) primaryButton(canvas, "Save changes", 20f, AI_REFRESH_TOP, 460f, 64f);
        else button(canvas, "Save", 20f, AI_REFRESH_TOP, 460f, 64f);
    }

    private void aiRow(Canvas canvas, float top, float bottom, String label, String value, int valueColor) {
        SamTheme.glass(canvas, paint, new RectF(20f, top, 460f, bottom), 20f, false);
        float mid = (top + bottom) / 2f;
        SamTheme.text(canvas, paint, label, 42f, mid - 8f, 15f,
                SamTheme.MUTED, Paint.Align.LEFT, false);
        paint.setTextSize(23f);
        paint.setTypeface(android.graphics.Typeface.create("sans-serif-medium",
                android.graphics.Typeface.NORMAL));
        SamTheme.text(canvas, paint, ellipsize(value, 340f), 42f, mid + 22f, 23f,
                valueColor, Paint.Align.LEFT, true);
        stepper(canvas, mid);
    }

    /** Small glass disc marking the tap-to-cycle zone (x 390..460) of an AI row. */
    private void stepper(Canvas canvas, float centerY) {
        RectF disc = new RectF(403f, centerY - 22f, 447f, centerY + 22f);
        SamTheme.glass(canvas, paint, disc, 22f, false);
        chevron(canvas, 426f, centerY, SamTheme.ORB_PALE);
    }

    private String accessLabel(String accessPath) {
        if ("platform".equals(accessPath)) return "OpenAI Platform API";
        if ("subscription".equals(accessPath)) return "ChatGPT / Codex";
        return accessPath == null || accessPath.isBlank() ? "—" : accessPath;
    }

    private static String sentence(String value) {
        if (value == null || value.isEmpty()) return "";
        String lower = value.toLowerCase();
        return Character.toUpperCase(lower.charAt(0)) + lower.substring(1);
    }

    /** Ellipsizes using the paint's current text size and typeface. */
    private String ellipsize(String value, float width) {
        if (value == null) return "";
        if (paint.measureText(value) <= width) return value;
        int count = paint.breakText(value, true, width - paint.measureText("…"), null);
        return value.substring(0, Math.max(0, count)).trim() + "…";
    }

    private void chevron(Canvas canvas, float cx, float cy, int color) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.4f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(color);
        canvas.drawLine(cx - 3f, cy - 7f, cx + 4f, cy, paint);
        canvas.drawLine(cx + 4f, cy, cx - 3f, cy + 7f, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    /** Static, cheap orb glyph: white crown fading to orb blue. */
    private void orbDot(Canvas canvas, float cx, float cy, float r) {
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new RadialGradient(cx, cy + r * 0.3f, r * 2.2f,
                SamTheme.withAlpha(SamTheme.ORB_BLUE, 80),
                SamTheme.withAlpha(SamTheme.ORB_BLUE, 0), Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy + r * 0.3f, r * 2.2f, paint);
        paint.setShader(new LinearGradient(cx, cy - r, cx, cy + r,
                new int[]{0xffffffff, SamTheme.ORB_PALE, SamTheme.ORB_BLUE},
                new float[]{0.15f, 0.5f, 0.9f}, Shader.TileMode.CLAMP));
        canvas.drawCircle(cx, cy, r, paint);
        paint.setShader(null);
    }

    private void drawBluetoothGlyph(Canvas canvas, float cx, float cy, float scale, int color) {
        Path path = glyph;
        path.reset();
        path.moveTo(cx - 6f * scale, cy - 5f * scale);
        path.lineTo(cx + 6f * scale, cy + 6f * scale);
        path.lineTo(cx, cy + 11f * scale);
        path.lineTo(cx, cy - 11f * scale);
        path.lineTo(cx + 6f * scale, cy - 6f * scale);
        path.lineTo(cx - 6f * scale, cy + 5f * scale);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.4f + scale);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(color);
        canvas.drawPath(path, paint);
        paint.setStrokeJoin(Paint.Join.MITER);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    /** Simple line icons for the index rows, drawn in the pale orb tint; allocation-free. */
    private void drawRowIcon(Canvas canvas, String row, float cx, float cy) {
        int color = SamTheme.ORB_PALE;
        if ("Bluetooth".equals(row)) { drawBluetoothGlyph(canvas, cx, cy, 0.85f, color); return; }
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(color);
        switch (row) {
            case "Wi-Fi" -> {
                canvas.drawArc(cx - 6f, cy - 1f, cx + 6f, cy + 11f, -135f, 90f, false, paint);
                canvas.drawArc(cx - 11f, cy - 6f, cx + 11f, cy + 16f, -135f, 90f, false, paint);
                paint.setStyle(Paint.Style.FILL);
                canvas.drawCircle(cx, cy + 4f, 2f, paint);
            }
            case THEME -> drawThemeGlyph(canvas, cx, cy);
            case "Management" -> {
                canvas.drawRoundRect(cx - 9f, cy - 8f, cx + 9f, cy + 4f, 2f, 2f, paint);
                canvas.drawLine(cx - 12f, cy + 8f, cx + 12f, cy + 8f, paint);
            }
            case "AI" -> {
                glyph.reset();
                glyph.moveTo(cx, cy - 10f);
                glyph.quadTo(cx + 1f, cy - 1f, cx + 10f, cy);
                glyph.quadTo(cx + 1f, cy + 1f, cx, cy + 10f);
                glyph.quadTo(cx - 1f, cy + 1f, cx - 10f, cy);
                glyph.quadTo(cx - 1f, cy - 1f, cx, cy - 10f);
                paint.setStyle(Paint.Style.FILL);
                canvas.drawPath(glyph, paint);
            }
            case "Creations" -> {
                float s = 7f, g = 2f;
                canvas.drawRoundRect(cx - g - s, cy - g - s, cx - g, cy - g, 2f, 2f, paint);
                canvas.drawRoundRect(cx + g, cy - g - s, cx + g + s, cy - g, 2f, 2f, paint);
                canvas.drawRoundRect(cx - g - s, cy + g, cx - g, cy + g + s, 2f, 2f, paint);
                canvas.drawRoundRect(cx + g, cy + g, cx + g + s, cy + g + s, 2f, 2f, paint);
            }
            case "Sound" -> {
                glyph.reset();
                glyph.moveTo(cx - 10f, cy - 4f);
                glyph.lineTo(cx - 5f, cy - 4f);
                glyph.lineTo(cx + 1f, cy - 9f);
                glyph.lineTo(cx + 1f, cy + 9f);
                glyph.lineTo(cx - 5f, cy + 4f);
                glyph.lineTo(cx - 10f, cy + 4f);
                glyph.close();
                canvas.drawPath(glyph, paint);
                canvas.drawArc(cx - 3f, cy - 7f, cx + 9f, cy + 7f, -50f, 100f, false, paint);
            }
            case SIDE_BUTTON -> {
                // The R1 seen edge-on: its body and the side button standing out on the right.
                canvas.drawRoundRect(cx - 9f, cy - 11f, cx + 5f, cy + 11f, 4f, 4f, paint);
                paint.setStyle(Paint.Style.FILL);
                canvas.drawRoundRect(cx + 7f, cy - 7f, cx + 11f, cy + 1f, 2f, 2f, paint);
            }
            case "Display" -> {
                canvas.drawCircle(cx, cy, 4.5f, paint);
                for (int i = 0; i < 8; i++) {
                    double a = Math.PI / 4 * i;
                    float cos = (float) Math.cos(a), sin = (float) Math.sin(a);
                    canvas.drawLine(cx + cos * 8f, cy + sin * 8f, cx + cos * 11f, cy + sin * 11f, paint);
                }
            }
            default -> {
                canvas.drawCircle(cx, cy, 10f, paint);
                canvas.drawLine(cx, cy - 1f, cx, cy + 5f, paint);
                paint.setStyle(Paint.Style.FILL);
                canvas.drawCircle(cx, cy - 5f, 1.5f, paint);
            }
        }
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeJoin(Paint.Join.MITER);
        paint.setStyle(Paint.Style.FILL);
    }

    /**
     * Theme: a disc that is smooth orb on the left and stepped pixels on the right, the two
     * looks the page switches between.
     */
    private void drawThemeGlyph(Canvas canvas, float cx, float cy) {
        paint.setStyle(Paint.Style.FILL);
        canvas.drawArc(cx - 10f, cy - 10f, cx + 10f, cy + 10f, 90f, 180f, true, paint);
        float cell = 4f;
        float gap = 1f;
        // Right half as pixels: a column of four cells, then a shorter column of three.
        for (int i = 0; i < 4; i++) {
            float top = cy - 10f + i * (cell + gap) + 0.5f;
            canvas.drawRect(cx + 1f, top, cx + 1f + cell, top + cell, paint);
        }
        for (int i = 0; i < 3; i++) {
            float top = cy - 7.5f + i * (cell + gap);
            canvas.drawRect(cx + 1f + cell + gap, top, cx + 1f + 2f * cell + gap, top + cell, paint);
        }
    }

    private void refreshOpenAi() {
        openAiMessage = "Refreshing AI settings…";
        openAiState = ManagementOpenAiState.loading();
        invalidate();
        openAiSource.refresh(activity, state -> {
            openAiState = state;
            syncAiDraft(state);
            openAiMessage = state.fallbackMessage() == null
                    ? "" : state.fallbackMessage();
            invalidate();
        });
    }

    private void syncAiDraft(ManagementOpenAiState state) {
        draftProvider = state.provider();
        draftAccessPath = state.accessPath();
        draftTextModel = state.selectedTextModel();
        draftRealtimeModel = state.selectedRealtimeModel();
        draftReasoning = state.reasoningEffort() == null ? "none" : state.reasoningEffort();
        aiDraftDirty = false;
    }

    private String providerLabel(String provider) {
        String[] ids = openAiState.providerIds();
        String[] names = openAiState.providerNames();
        for (int i = 0; i < ids.length && i < names.length; i++) {
            if (ids[i].equals(provider)) return names[i];
        }
        return provider;
    }

    static String nextOption(String current, String[] options) {
        if (options == null || options.length == 0) return current;
        for (int i = 0; i < options.length; i++) {
            if (options[i].equals(current)) return options[(i + 1) % options.length];
        }
        return options[0];
    }

    private void cycleProvider() {
        draftProvider = nextOption(draftProvider, openAiState.providerIds());
        markAiDraftChanged();
    }

    private void cycleAccessPath() {
        if (!openAiState.platformConnected() && !openAiState.subscriptionConnected()) {
            openAiMessage = "Connect OpenAI in management first.";
            invalidate();
            return;
        }
        if (openAiState.platformConnected() && openAiState.subscriptionConnected()) {
            draftAccessPath = nextOption(draftAccessPath, new String[]{"platform", "subscription"});
        } else {
            draftAccessPath = openAiState.platformConnected() ? "platform" : "subscription";
        }
        markAiDraftChanged();
    }

    private void cycleRealtimeModel() {
        draftRealtimeModel = nextOption(draftRealtimeModel, openAiState.realtimeModels());
        markAiDraftChanged();
    }

    private void cycleTextModel() {
        draftTextModel = nextOption(draftTextModel, openAiState.textModels());
        markAiDraftChanged();
    }

    private void cycleReasoning() {
        draftReasoning = nextOption(draftReasoning, new String[]{"none", "low", "medium", "high"});
        markAiDraftChanged();
    }

    private void markAiDraftChanged() {
        aiDraftDirty = true;
        openAiMessage = "Unsaved changes";
        invalidate();
    }

    private void saveAiDraft() {
        if (!aiDraftDirty) {
            openAiMessage = "Settings are already saved.";
            invalidate();
            return;
        }
        openAiMessage = "Saving AI settings…";
        invalidate();
        openAiSource.setProvider(activity, draftProvider, providerState -> {
            if (providerState.error()) { finishAiSave(providerState); return; }
            openAiSource.setAccessPath(activity, draftAccessPath, accessState -> {
                if (accessState.error()) { finishAiSave(accessState); return; }
                openAiSource.setModels(
                        activity,
                        draftTextModel,
                        draftRealtimeModel,
                        draftReasoning,
                        this::finishAiSave);
            });
        });
    }

    private void finishAiSave(ManagementOpenAiState state) {
        openAiState = state;
        if (state.error()) {
            openAiMessage = state.fallbackMessage() == null ? "AI settings were not saved." : state.fallbackMessage();
        } else {
            syncAiDraft(state);
            openAiMessage = "AI settings saved.";
        }
        invalidate();
    }

    private void pickProvider() {
        String[] ids = openAiState.providerIds();
        if (ids.length == 0) {
            openAiMessage = "No providers available.";
            invalidate();
            return;
        }
        int checked = 0;
        String[] labels = new String[ids.length];
        for (int i = 0; i < ids.length; i++) {
            if (ids[i].equals(openAiState.provider())) checked = i;
            labels[i] = openAiState.providerNames()[i] + " (" + ids[i] + ")";
        }
        new AlertDialog.Builder(activity)
                .setTitle("Select provider")
                .setSingleChoiceItems(labels, checked, (dialog, which) -> {
                    dialog.dismiss();
                    setProvider(ids[which]);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void setProvider(String provider) {
        openAiMessage = "Saving provider…";
        invalidate();
        openAiSource.setProvider(activity, provider, state -> {
            openAiState = state;
            openAiMessage = "Provider set.";
            invalidate();
        });
    }

    private void pickAccessPath() {
        if (!openAiState.platformConnected() && !openAiState.subscriptionConnected()) {
            openAiMessage = "Connect OpenAI first.";
            invalidate();
            return;
        }
        String[] options = new String[2];
        String[] optionValues = new String[2];
        int total = 0;
        if (openAiState.platformConnected()) {
            optionValues[total] = "platform";
            options[total] = "OpenAI Platform API";
            total++;
        }
        if (openAiState.subscriptionConnected()) {
            optionValues[total] = "subscription";
            options[total] = "ChatGPT / Codex";
            total++;
        }
        String[] visible = new String[total];
        String[] values = new String[total];
        for (int i = 0; i < total; i++) {
            visible[i] = options[i];
            values[i] = optionValues[i];
        }
        if (total == 0) {
            openAiMessage = "No access path is available.";
            invalidate();
            return;
        }
        int checked = 0;
        for (int i = 0; i < total; i++) {
            if (values[i].equals(openAiState.accessPath())) checked = i;
        }
        new AlertDialog.Builder(activity)
                .setTitle("Use for text and Voice")
                .setSingleChoiceItems(visible, checked, (dialog, which) -> {
                    dialog.dismiss();
                    setAccessPath(values[which]);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void setAccessPath(String accessPath) {
        openAiMessage = "Saving connection type…";
        invalidate();
        openAiSource.setAccessPath(activity, accessPath, state -> {
            openAiState = state;
            openAiMessage = "Connection updated.";
            invalidate();
        });
    }

    private void pickRealtimeModel() {
        String[] options = openAiState.realtimeModels();
        if (options.length == 0) {
            openAiMessage = "Refresh after connecting to OpenAI.";
            invalidate();
            return;
        }
        showSingleChoice("Select voice model", options, openAiState.selectedRealtimeModel(), value ->
                setModels(openAiState.selectedTextModel(), value, openAiState.reasoningEffort())
        );
    }

    private void pickTextModel() {
        String[] options = openAiState.textModels();
        if (options.length == 0) {
            openAiMessage = "Refresh after connecting to OpenAI.";
            invalidate();
            return;
        }
        showSingleChoice("Select text model", options, openAiState.selectedTextModel(), value ->
                setModels(value, openAiState.selectedRealtimeModel(), openAiState.reasoningEffort())
        );
    }

    private void pickReasoning() {
        String[] options = new String[]{"none", "low", "medium", "high"};
        showSingleChoice("Reasoning", options, openAiState.reasoningEffort(), value ->
                setModels(openAiState.selectedTextModel(), openAiState.selectedRealtimeModel(), value)
        );
    }

    private void showSingleChoice(String title, String[] values, String checkedValue, ChoiceHandler handler) {
        int checked = 0;
        for (int i = 0; i < values.length; i++) {
            if (values[i].equals(checkedValue)) checked = i;
        }
        new AlertDialog.Builder(activity)
                .setTitle(title)
                .setSingleChoiceItems(values, checked, (dialog, which) -> {
                    dialog.dismiss();
                    handler.onChoice(values[which]);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void setModels(String textModel, String realtimeModel, String reasoningEffort) {
        openAiMessage = "Saving models…";
        openAiSource.setModels(activity, textModel, realtimeModel, reasoningEffort, state -> {
            openAiState = state;
            openAiMessage = "Model selection saved.";
            invalidate();
        });
    }

    private void connectOpenAiFromSettings() {
        // A secret: keyboard only, never dictated (the transcriber would hear the key).
        ComposeSheet.open(activity, new ComposeSheet.Options()
                .title("OpenAI Platform API key")
                .hint("sk-…")
                .action("Save")
                .secret(true), value -> {
            if (value.isBlank()) {
                openAiMessage = "Key cannot be empty.";
                invalidate();
                return;
            }
            openAiMessage = "Saving key…";
            invalidate();
            openAiSource.connect(activity, value.trim(), state -> {
                openAiState = state;
                openAiMessage = "OpenAI key connected.";
                invalidate();
            });
        });
    }

    @FunctionalInterface
    private interface ChoiceHandler {
        void onChoice(String value);
    }

    private void refreshManagement() {
        managementState = ManagementPairingState.loading();
        invalidate();
        managementPairing.load(state -> {
            managementState = state;
            invalidate();
        });
    }

    private void drawBack(Canvas canvas) {
        glassPainter.draw(canvas, paint, BACK_DISC, 22f, false);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.6f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.INK);
        canvas.drawLine(36f, 34f, 27f, 44f, paint);
        canvas.drawLine(27f, 44f, 36f, 54f, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    private void drawClose(Canvas canvas) {
        glassPainter.draw(canvas, paint, CLOSE_DISC, 24f, false);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.4f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.INK);
        canvas.drawLine(431f, 37f, 445f, 51f, paint);
        canvas.drawLine(445f, 37f, 431f, 51f, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    private SettingValue[] statusValues(String page) {
        return switch (page) {
            case "Wi-Fi" -> network();
            case "Bluetooth" -> bluetooth();
            case "Sound" -> sound();
            case "Display" -> display();
            default -> new SettingValue[]{
                    new SettingValue("DEVICE", "Rabbit R1"),
                    new SettingValue("VERSION", appVersion()),
                    new SettingValue("ANDROID", android.os.Build.VERSION.RELEASE)};
        };
    }

    private String appVersion() {
        try {
            String version = activity.getPackageManager()
                    .getPackageInfo(activity.getPackageName(), 0).versionName;
            return version == null || version.isBlank() ? "Unavailable" : version.replace('-', ' ');
        } catch (android.content.pm.PackageManager.NameNotFoundException unavailable) {
            return "Unavailable";
        }
    }

    private SettingValue[] network() {
        WifiManager wifi = activity.getSystemService(WifiManager.class);
        ConnectivityManager cm = activity.getSystemService(ConnectivityManager.class);
        Network network = cm == null ? null : cm.getActiveNetwork();
        NetworkCapabilities caps = network == null || cm == null
                ? null : cm.getNetworkCapabilities(network);
        boolean validated = caps != null
                && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        return new SettingValue[]{
                new SettingValue("WI-FI", wifi != null && wifi.isWifiEnabled() ? "On" : "Off"),
                new SettingValue("INTERNET", validated ? "Connected" : "Offline")};
    }

    private SettingValue[] bluetooth() {
        BluetoothManager manager = activity.getSystemService(BluetoothManager.class);
        BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
        return new SettingValue[]{
                new SettingValue("BLUETOOTH", adapter != null && adapter.isEnabled() ? "On" : "Off"),
                new SettingValue("STATUS", bluetoothStatus)};
    }

    private boolean isBluetoothEnabled() {
        BluetoothManager manager = activity.getSystemService(BluetoothManager.class);
        BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
        return adapter != null && adapter.isEnabled();
    }

    @SuppressWarnings("deprecation")
    private void toggleBluetooth() {
        if (android.os.Build.VERSION.SDK_INT >= 31
                && activity.checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            // The embedded R1 image owns this grant. Never prompt the owner.
            bluetoothStatus = "System grant unavailable";
            invalidate();
            return;
        }
        BluetoothManager manager = activity.getSystemService(BluetoothManager.class);
        BluetoothAdapter adapter = manager == null ? null : manager.getAdapter();
        if (adapter == null) {
            bluetoothStatus = "Adapter unavailable";
            invalidate();
            return;
        }
        try {
            boolean enabling = !adapter.isEnabled();
            boolean accepted = enabling ? adapter.enable() : adapter.disable();
            bluetoothStatus = accepted
                    ? (enabling ? "Turning on…" : "Turning off…")
                    : "System rejected request";
        } catch (SecurityException denied) {
            bluetoothStatus = "System permission unavailable";
        }
        invalidate();
        // MediaTek moves through BLE_TURNING_ON/OFF before the final adapter
        // state. The broadcast is authoritative; these redraws also cover a
        // missed transition without pretending the 500 ms state is final.
        postDelayed(this::invalidate, 500L);
        postDelayed(this::invalidate, 1_500L);
        postDelayed(this::invalidate, 3_000L);
    }

    static String bluetoothStateLabel(int state) {
        return switch (state) {
            case BluetoothAdapter.STATE_ON -> "Enabled";
            case BluetoothAdapter.STATE_OFF -> "Disabled";
            case BluetoothAdapter.STATE_TURNING_ON -> "Turning on…";
            case BluetoothAdapter.STATE_TURNING_OFF -> "Turning off…";
            default -> "State unavailable";
        };
    }

    private SettingValue[] sound() {
        AudioManager audio = activity.getSystemService(AudioManager.class);
        int current = audio == null ? 0 : audio.getStreamVolume(AudioManager.STREAM_MUSIC);
        int max = audio == null ? 0 : audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        int percent = max == 0 ? 0 : Math.round(current * 100f / max);
        return new SettingValue[]{new SettingValue("VOLUME", percent + "%")};
    }

    private SettingValue[] display() {
        int brightness = Settings.System.getInt(activity.getContentResolver(),
                Settings.System.SCREEN_BRIGHTNESS, 0);
        return new SettingValue[]{
                new SettingValue("BRIGHTNESS", Math.round(brightness * 100f / 255f) + "%"),
                new SettingValue("SCREEN OFF", IdleScreenSetting.never(activity) ? "Never" : "After 10 min")};
    }

    private void button(Canvas canvas, String label, float left, float top, float right) {
        button(canvas, label, left, top, right, 72f);
    }

    private void button(Canvas canvas, String label, float left, float top, float right, float height) {
        RectF rect = buttonRect;
        rect.set(left, top, right, top + height);
        glassPainter.draw(canvas, paint, rect, 24f, false);
        boolean glyph = label.length() == 1;
        SamTheme.text(canvas, paint, label, rect.centerX(), rect.centerY() + (glyph ? 12f : 8f),
                glyph ? 38f : 22f, SamTheme.INK, Paint.Align.CENTER, true);
    }

    private void primaryButton(Canvas canvas, String label, float left, float top, float right) {
        primaryButton(canvas, label, left, top, right, 72f);
    }

    private void primaryButton(Canvas canvas, String label, float left, float top, float right, float height) {
        RectF rect = new RectF(left, top, right, top + height);
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new LinearGradient(0f, rect.top, 0f, rect.bottom,
                SamTheme.withAlpha(SamTheme.ORB_BLUE, 240),
                SamTheme.withAlpha(SamTheme.ORB_BLUE, 195), Shader.TileMode.CLAMP));
        canvas.drawRoundRect(rect, 24f, 24f, paint);
        paint.setShader(null);
        SamTheme.text(canvas, paint, label, rect.centerX(), rect.centerY() + 8f, 22f,
                SamTheme.INK, Paint.Align.CENTER, true);
    }

    private void adjustVolume(boolean increase) {
        AudioManager audio = activity.getSystemService(AudioManager.class);
        if (audio != null) audio.adjustStreamVolume(AudioManager.STREAM_MUSIC,
                increase ? AudioManager.ADJUST_RAISE : AudioManager.ADJUST_LOWER, 0);
        invalidate();
    }

    private void adjustBrightness(boolean increase) {
        int current = Settings.System.getInt(activity.getContentResolver(),
                Settings.System.SCREEN_BRIGHTNESS, 128);
        int next = adjustedBrightness(current, increase);
        try {
            Settings.System.putInt(activity.getContentResolver(),
                    Settings.System.SCREEN_BRIGHTNESS_MODE,
                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL);
            if (Settings.System.putInt(activity.getContentResolver(),
                    Settings.System.SCREEN_BRIGHTNESS, next)) {
                WindowManager.LayoutParams params = activity.getWindow().getAttributes();
                params.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE;
                activity.getWindow().setAttributes(params);
            }
        } catch (SecurityException ignored) {
            // The standalone system image owns the privileged Settings grant.
            // Keep the displayed value authoritative if that grant is absent.
        }
        invalidate();
    }

    static int adjustedBrightness(int current, boolean increase) {
        int bounded = Math.max(13, Math.min(255, current));
        return Math.max(13, Math.min(255, bounded + (increase ? 26 : -26)));
    }

    private void selectNetwork(WifiNetworkScanner.Network network) {
        if (network.connected()) return;
        if (!network.secured()) {
            connect(network.ssid(), null);
            return;
        }
        // A secret: keyboard only, never dictated.
        ComposeSheet.open(activity, new ComposeSheet.Options()
                .title("Wi-Fi password for " + network.ssid())
                .hint("Network password")
                .action("Connect")
                .secret(true), value -> connect(network.ssid(), value));
    }

    @SuppressWarnings("deprecation")
    private void connect(String ssid, String password) {
        WifiManager wifi = activity.getSystemService(WifiManager.class);
        if (wifi == null) { wifiScanState = "Wi-Fi unavailable"; invalidate(); return; }
        WifiConfiguration config = new WifiConfiguration();
        config.SSID = quote(ssid);
        if (password == null || password.isBlank()) config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
        else config.preSharedKey = quote(password);
        try {
            int id = wifi.addNetwork(config);
            if (id < 0) { wifiScanState = "Could not save network"; invalidate(); return; }
            wifi.disconnect();
            wifi.enableNetwork(id, true);
            wifi.reconnect();
            wifiScanState = "Connecting to " + ssid + "…";
            postDelayed(wifiScanner::refresh, 1800L);
        } catch (SecurityException denied) {
            wifiScanState = "System Wi-Fi permission unavailable";
        }
        invalidate();
    }

    private static String quote(String value) { return '"' + value.replace("\"", "\\\"") + '"'; }

    @Override public boolean onTouchEvent(MotionEvent event) {
        float x = event.getX() * DESIGN_WIDTH / Math.max(1f, getWidth());
        float y = event.getY() * DESIGN_HEIGHT / Math.max(1f, getHeight());
        boolean list = openPage == null;
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN -> {
                downX = x;
                downY = y;
                lastY = y;
                dragging = false;
                // A touch that stops a fling (or the wheel's glide) is not also a tap.
                caughtMotion = list && (!scroller.isFinished() || Math.abs(scrollTarget - scroll) > 2f);
                scroller.forceFinished(true);
                scrollTarget = scroll;
                if (list) {
                    if (velocity == null) velocity = VelocityTracker.obtain();
                    velocity.clear();
                    velocity.addMovement(event);
                }
            }
            case MotionEvent.ACTION_MOVE -> {
                if (list) {
                    if (velocity != null) velocity.addMovement(event);
                    if (!dragging && Math.abs(y - downY) > TOUCH_SLOP
                            && SettingsListLayout.maxScroll(ROWS.size()) > 0f) {
                        dragging = true;
                    }
                    if (dragging) {
                        scroll = SettingsListLayout.clamp(scroll - (y - lastY), ROWS.size());
                        scrollTarget = scroll;
                        invalidate();
                    }
                }
                lastY = y;
            }
            case MotionEvent.ACTION_UP -> {
                if (dragging) {
                    if (velocity != null) velocity.addMovement(event);
                    fling();
                } else if (!caughtMotion || y < SettingsListLayout.VIEW_TOP) {
                    onTap(x, y);
                }
                endTouch();
            }
            // The left-edge back swipe (and anything else the parent takes) lands here: no tap.
            case MotionEvent.ACTION_CANCEL -> endTouch();
            default -> { }
        }
        return true;
    }

    /** Lets a dragged list coast; OverScroller's bounds stop it at either end (no overscroll). */
    private void fling() {
        if (velocity == null) return;
        velocity.computeCurrentVelocity(1000);
        float vy = velocity.getYVelocity() * DESIGN_HEIGHT / Math.max(1f, getHeight());
        int max = Math.round(SettingsListLayout.maxScroll(ROWS.size()));
        scroller.fling(0, Math.round(scroll), 0, Math.round(-vy), 0, 0, 0, max);
        postInvalidateOnAnimation();
    }

    private void endTouch() {
        if (velocity != null) {
            velocity.recycle();
            velocity = null;
        }
        dragging = false;
    }

    private void onTap(float x, float y) {
        if (x > 400f && y < 76f) { close.run(); return; }
        if (openPage != null && x < 90f && y < 82f) {
            goBack();
            return;
        }
        if ("Display".equals(openPage)) {
            onDisplayTap(x, y);
            return;
        }
        if (SIDE_BUTTON.equals(openPage)) {
            float within = (y - SIDE_OPTION_TOP) % (SIDE_OPTION_HEIGHT + SIDE_OPTION_GAP);
            int option = (int) Math.floor((y - SIDE_OPTION_TOP) / (SIDE_OPTION_HEIGHT + SIDE_OPTION_GAP));
            if (y >= SIDE_OPTION_TOP && option < SideButtonSetting.VoiceNote.values().length
                    && within <= SIDE_OPTION_HEIGHT) {
                chooseVoiceNote(option);
            }
            return;
        }
        if (THEME.equals(openPage)) {
            // A tile applies only when the press both starts and ends on it.
            int tile = ThemePageLayout.tileAt(x, y);
            if (tile >= 0 && tile == ThemePageLayout.tileAt(downX, downY)) {
                applyTheme(OrbStyle.values()[tile]);
            }
            return;
        }
        if (openPage == null) {
            // Rows sit under the fixed header: a tap in the header band never opens one.
            int row = SettingsListLayout.rowAt(y, scroll, ROWS.size());
            if (row >= 0) {
                selected = row;
                activateSelectedRow();
            }
        } else if ("Wi-Fi".equals(openPage)) {
            float networkTop = 148f;
            int row = (int) ((y - networkTop) / 59f);
            float within = (y - networkTop) % 59f;
            if (y >= networkTop && row >= 0 && row < Math.min(6, wifiNetworks.size()) && within <= 52f) {
                selectNetwork(wifiNetworks.get(row));
            } else if (y >= 520f && y <= 620f) {
                wifiScanner.refresh();
            }
        } else if ("AI".equals(openPage)) {
            boolean arrow = x >= 390f && x <= 460f;
            if (arrow && y >= AI_PROVIDER_TOP && y <= AI_PROVIDER_BOTTOM) {
                cycleProvider();
            } else if (arrow && y >= AI_ACCESS_TOP && y <= AI_ACCESS_BOTTOM) {
                cycleAccessPath();
            } else if (arrow && y >= AI_VOICE_MODEL_TOP && y <= AI_VOICE_MODEL_BOTTOM) {
                cycleRealtimeModel();
            } else if (arrow && y >= AI_TEXT_MODEL_TOP && y <= AI_TEXT_MODEL_BOTTOM) {
                cycleTextModel();
            } else if (arrow && y >= AI_REASONING_TOP && y <= AI_REASONING_BOTTOM) {
                cycleReasoning();
            } else if (y >= AI_REFRESH_TOP && y <= AI_REFRESH_TOP + 72f) {
                saveAiDraft();
            }
        } else if ("Sound".equals(openPage) && y >= ALWAYS_ON_TOP && y <= ALWAYS_ON_BOTTOM) {
            AlwaysOnVoice.setEnabled(activity, !AlwaysOnVoice.isEnabled(activity));
            invalidate();
        } else if (y >= 482f && y <= 584f) {
            if ("Sound".equals(openPage)) {
                adjustVolume(x >= DESIGN_WIDTH / 2f);
            } else if ("Bluetooth".equals(openPage)) {
                toggleBluetooth();
            } else if ("About".equals(openPage)) {
                restart.run();
            } else if ("Management".equals(openPage)) {
                refreshManagement();
            } else {
                invalidate();
            }
        }
    }

    @Override public boolean onInput(UiInputIntent intent) {
        if (intent == UiInputIntent.BACK) {
            goBack();
            return true;
        }
        if (openPage == null && (intent == UiInputIntent.PREVIOUS || intent == UiInputIntent.NEXT)) {
            int step = intent == UiInputIntent.NEXT ? 1 : -1;
            selected = Math.max(0, Math.min(ROWS.size() - 1, selected + step));
            revealSelected(true);
            invalidate();
            return true;
        }
        if (openPage == null && intent == UiInputIntent.ACTIVATE) {
            activateSelectedRow(); return true;
        }
        if ("Wi-Fi".equals(openPage) && intent == UiInputIntent.ACTIVATE) {
            if (!wifiNetworks.isEmpty()) selectNetwork(wifiNetworks.get(0));
            return true;
        }
        if (THEME.equals(openPage)) {
            if (intent == UiInputIntent.ACTIVATE) {
                applyTheme(OrbStyle.values()[themeFocus]);
            } else {
                themeFocus = SettingsInputPolicy.themeFocusForWheel(themeFocus, ThemePageLayout.TILES, intent);
                invalidate();
            }
            return true;
        }
        if (SIDE_BUTTON.equals(openPage)) {
            if (intent == UiInputIntent.ACTIVATE) chooseVoiceNote(sideFocus);
            else {
                sideFocus = SettingsInputPolicy.themeFocusForWheel(sideFocus,
                        SideButtonSetting.VoiceNote.values().length, intent);
                invalidate();
            }
            return true;
        }
        if (SettingsInputPolicy.consumeWheelWithoutAdjustment(openPage, intent)) {
            // Volume and brightness never follow the R1 wheel; they need
            // their explicit on-screen buttons.
            return true;
        }
        if ("Bluetooth".equals(openPage) && intent == UiInputIntent.ACTIVATE) {
            toggleBluetooth();
            return true;
        }
        if ("About".equals(openPage) && intent == UiInputIntent.ACTIVATE) {
            restart.run();
            return true;
        }
        if ("Management".equals(openPage) && intent == UiInputIntent.ACTIVATE) {
            refreshManagement();
            return true;
        }
        if ("AI".equals(openPage) && intent == UiInputIntent.ACTIVATE) {
            saveAiDraft();
            return true;
        }
        return false;
    }

    private void activateSelectedRow() {
        String page = ROWS.get(selected);
        if ("Creations".equals(page)) {
            openCreationImport.run();
            return;
        }
        themeReturn = null;
        showPage(page);
    }

    /** BACK, the back chevron and the edge swipe: a page goes back to the list (Theme to where it came from). */
    private void goBack() {
        if (openPage == null) {
            close.run();
            return;
        }
        String previous = THEME.equals(openPage) ? themeReturn : null;
        themeReturn = null;
        showPage(previous);
    }

    /** Opens {@code page} (null = the list) and refreshes what it shows. */
    private void showPage(String page) {
        openPage = page;
        if (page == null) {
            revealSelected(false);
        } else {
            switch (page) {
                case "Wi-Fi" -> wifiScanner.refresh();
                case "Management" -> refreshManagement();
                case "AI" -> refreshOpenAi();
                case "Display" -> displayValue = null;
                case SIDE_BUTTON -> sideFocus = SideButtonSetting.voiceNote(activity).ordinal();
                case "About" -> aboutValues = null;
                case THEME -> {
                    themeFocus = OrbStyleSetting.current().ordinal();
                    themeAppliedAt = -1L;
                }
                default -> { }
            }
        }
        updateThemePin();
        invalidate();
    }

    @Override public void onWindowFocusChanged(boolean hasWindowFocus) {
        super.onWindowFocusChanged(hasWindowFocus);
        wifiScanner.onWindowFocusChanged(hasWindowFocus);
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (bluetoothReceiverRegistered) return;
        IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(bluetoothReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            activity.registerReceiver(bluetoothReceiver, filter);
        }
        bluetoothReceiverRegistered = true;
    }

    @Override protected void onDetachedFromWindow() {
        wifiScanner.close();
        if (bluetoothReceiverRegistered) {
            try { activity.unregisterReceiver(bluetoothReceiver); }
            catch (IllegalArgumentException ignored) { }
            bluetoothReceiverRegistered = false;
        }
        super.onDetachedFromWindow();
    }

    private record SettingValue(String label, String value) { }
}
