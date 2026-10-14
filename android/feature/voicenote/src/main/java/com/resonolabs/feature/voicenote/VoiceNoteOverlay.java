package com.resonolabs.feature.voicenote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;

import com.resonolabs.ui.design.FluidOrb;
import com.resonolabs.ui.design.GlassPainter;
import com.resonolabs.ui.design.SamTheme;
import com.resonolabs.ui.design.TextFit;

/**
 * The voice note on screen, over whatever page is open: a big pulsing orb while it records ("Recording…
 * tap to send", the live words, a countdown near the 3-minute cap), then "Sent ✓ — Added to your journal"
 * for a moment. A tap finishes and sends; BACK (handled by the shell) cancels. While it sends, a tap
 * gives the screen back (the note still goes; its outcome comes as a chip).
 *
 * <p>Between notes it can show a small chip at the top for an outcome that arrived later (a note that
 * waited for the Mac): touches outside the chip go through to the page below.
 *
 * <p>Drawn in the 480x640 logical space; texts are wrapped when they change, never in onDraw.
 */
public final class VoiceNoteOverlay extends View {
    private static final float W = 480f, H = 640f;
    /** Below the system's microphone chip, which shows at the top while a note records. */
    private static final float HEADER_Y = 98f;
    private static final float ORB_X = 240f, ORB_Y = 262f, ORB_R = 100f;
    private static final long CHIP_MS = 4_500L;
    /** Recording red (the orb), saved green, waiting amber. */
    public static final int RECORDING = Color.rgb(255, 96, 110);
    public static final int SUCCESS = Color.rgb(96, 214, 160);

    private final VoiceNoteController controller;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint measure = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final FluidOrb orb = new FluidOrb().setColor(RECORDING).setSpeed(1.1f);
    private final GlassPainter glass = new GlassPainter();
    private final RectF arc = new RectF();
    private final RectF chipRect = new RectF(24f, 18f, 456f, 80f);
    private final Typeface medium = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    private final Typeface regular = Typeface.create("sans-serif", Typeface.NORMAL);
    private String wrappedWordsFrom;
    private String[] wordLines = new String[0];
    private String wrappedLineFrom;
    private String[] resultLines = new String[0];
    private long clockSecond = -1L;
    private String clockText = "0:00";
    private long countdownSecond = -1L;
    private String countdownText = "";
    private String chipText = "";
    private int chipColor = SUCCESS;
    private long chipUntil;
    private float smoothLevel;
    private float downX, downY;

    public VoiceNoteOverlay(Context context, VoiceNoteController controller) {
        super(context);
        this.controller = controller;
        setContentDescription("Voice note");
        setVisibility(GONE);
    }

    /** The controller changed (phase, words, level): re-layout texts and show or hide. */
    public void update() {
        relayout();
        boolean show = controller.showing() || chipShowing();
        if (show != (getVisibility() == VISIBLE)) setVisibility(show ? VISIBLE : GONE);
        if (show) invalidate();
    }

    /** A later outcome ("Voice note · Added to your journal"); {@code ok} false tints it amber. */
    public void showChip(String text, boolean ok) {
        if (text == null || text.isBlank()) return;
        chipText = TextFit.line(measure, "Voice note · " + text.trim(), 350f, 17f, medium);
        chipColor = ok ? SUCCESS : SamTheme.AMBER;
        chipUntil = SystemClock.uptimeMillis() + CHIP_MS;
        bringToFront();
        update();
        postDelayed(this::update, CHIP_MS + 50L);
    }

    /** A chip is on screen now (the next late outcome waits for it). */
    public boolean chipShowing() {
        return !chipText.isEmpty() && SystemClock.uptimeMillis() < chipUntil;
    }

    /** How long one chip stays up. */
    public static long chipMs() {
        return CHIP_MS;
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        float x = event.getX() * W / Math.max(1f, getWidth());
        float y = event.getY() * H / Math.max(1f, getHeight());
        boolean note = controller.showing();
        if (!note) {
            if (!chipShowing() || !chipRect.contains(x, y)) return false;
            if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                chipUntil = 0L;
                update();
            }
            return true;
        }
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN -> { downX = x; downY = y; }
            case MotionEvent.ACTION_UP -> {
                if (Math.abs(x - downX) < 40f && Math.abs(y - downY) < 40f) {
                    if (controller.recording()) controller.finish();
                    else if (!controller.sendInBackground()) controller.dismissResult();
                }
            }
            default -> { }
        }
        return true;
    }

    @Override protected void onDraw(Canvas canvas) {
        canvas.save();
        canvas.scale(getWidth() / W, getHeight() / H);
        boolean animating;
        if (controller.showing()) {
            drawNote(canvas);
            animating = true;
        } else {
            animating = chipShowing();
            if (animating) drawChip(canvas);
        }
        canvas.restore();
        if (animating) postInvalidateOnAnimation();
    }

    private void drawNote(Canvas canvas) {
        VoiceNoteMachine machine = controller.machine();
        VoiceNoteMachine.Phase phase = machine.phase();
        long now = SystemClock.elapsedRealtime();
        int color = colorFor(phase);
        float level = phase == VoiceNoteMachine.Phase.LISTENING ? Math.min(1f, controller.level() * 1.6f) : 0f;
        smoothLevel += (level - smoothLevel) * 0.25f;
        SamTheme.background(canvas, paint, W, H, ORB_X, ORB_Y + 20f, 330f, color);
        // Header: a red dot and VOICE NOTE, the time recorded on the right.
        paint.setColor(color);
        canvas.drawCircle(44f, HEADER_Y - 6f, 6f, paint);
        paint.setLetterSpacing(0.16f);
        SamTheme.text(canvas, paint, "VOICE NOTE", 60f, HEADER_Y, 15f, SamTheme.withAlpha(SamTheme.INK, 220),
                Paint.Align.LEFT, true);
        paint.setLetterSpacing(0f);
        if (machine.durationMs(now) > 0L || phase == VoiceNoteMachine.Phase.LISTENING) {
            SamTheme.text(canvas, paint, clock(machine.durationMs(now)), 436f, HEADER_Y, 17f, SamTheme.MUTED,
                    Paint.Align.RIGHT, false);
        }
        // The orb: lively and pulsing with the voice while recording, calm once it is over.
        boolean listening = phase == VoiceNoteMachine.Phase.LISTENING;
        orb.setColor(color);
        orb.setEnergy(listening ? 0.35f + smoothLevel * 0.65f : machine.active() ? 0.18f : 0.05f);
        orb.setSpeed(listening ? 1.2f : 0.6f);
        float pulse = listening ? (float) Math.sin(now / 260.0) * 3f + smoothLevel * 10f : 0f;
        if (listening) {
            float ring = ORB_R + 18f + smoothLevel * 26f;
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(3f);
            paint.setColor(SamTheme.withAlpha(color, 70 + (int) (smoothLevel * 120f)));
            canvas.drawCircle(ORB_X, ORB_Y, ring, paint);
            paint.setStyle(Paint.Style.FILL);
        }
        orb.draw(canvas, ORB_X, ORB_Y, ORB_R + pulse);
        if (phase == VoiceNoteMachine.Phase.FINISHING || phase == VoiceNoteMachine.Phase.SENDING
                || phase == VoiceNoteMachine.Phase.STARTING) {
            drawSpinner(canvas, now, color);
        } else if (phase == VoiceNoteMachine.Phase.SENT || phase == VoiceNoteMachine.Phase.QUEUED) {
            drawCheck(canvas);
        } else if (!machine.active()) {
            drawDash(canvas);
        }
        SamTheme.text(canvas, paint, machine.title(), 240f, 446f, 32f, SamTheme.INK, Paint.Align.CENTER, true);
        float y = 482f;
        if (machine.active()) {
            String hint = machine.hint();
            if (!hint.isEmpty()) {
                SamTheme.text(canvas, paint, hint, 240f, y, 16f, SamTheme.MUTED, Paint.Align.CENTER, false);
            }
            y = 522f;
            for (String line : wordLines) {
                SamTheme.text(canvas, paint, line, 240f, y, 19f, SamTheme.withAlpha(SamTheme.INK, 205),
                        Paint.Align.CENTER, false);
                y += 27f;
            }
            if (machine.countdown(now, controller.maxListenMs())) {
                SamTheme.text(canvas, paint, countdown(machine.remainingMs(now, controller.maxListenMs())), 436f,
                        HEADER_Y + 26f, 15f, SamTheme.AMBER, Paint.Align.RIGHT, true);
            }
        } else {
            for (String line : resultLines) {
                SamTheme.text(canvas, paint, line, 240f, y, 20f, SamTheme.withAlpha(SamTheme.INK, 225),
                        Paint.Align.CENTER, false);
                y += 28f;
            }
            SamTheme.text(canvas, paint, machine.hint(), 240f, 612f, 15f, SamTheme.withAlpha(SamTheme.MUTED, 200),
                    Paint.Align.CENTER, false);
        }
    }

    private void drawChip(Canvas canvas) {
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.PANEL);
        canvas.drawRoundRect(chipRect, 31f, 31f, paint);
        glass.draw(canvas, paint, chipRect, 31f, false);
        paint.setColor(chipColor);
        canvas.drawCircle(chipRect.left + 30f, chipRect.centerY(), 7f, paint);
        SamTheme.text(canvas, paint, chipText, chipRect.left + 50f, chipRect.centerY() + 6f, 17f, SamTheme.INK,
                Paint.Align.LEFT, true);
    }

    private void drawSpinner(Canvas canvas, long now, int color) {
        float r = ORB_R + 16f;
        arc.set(ORB_X - r, ORB_Y - r, ORB_X + r, ORB_Y + r);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(4f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.withAlpha(color, 200));
        canvas.drawArc(arc, (now % 1200L) * 0.3f, 80f, false, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    private void drawCheck(Canvas canvas) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(11f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(Color.WHITE);
        canvas.drawLine(ORB_X - 38f, ORB_Y + 2f, ORB_X - 10f, ORB_Y + 30f, paint);
        canvas.drawLine(ORB_X - 10f, ORB_Y + 30f, ORB_X + 42f, ORB_Y - 28f, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStrokeJoin(Paint.Join.MITER);
        paint.setStyle(Paint.Style.FILL);
    }

    private void drawDash(Canvas canvas) {
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(11f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.withAlpha(Color.WHITE, 230));
        canvas.drawLine(ORB_X - 34f, ORB_Y, ORB_X + 34f, ORB_Y, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    private static int colorFor(VoiceNoteMachine.Phase phase) {
        return switch (phase) {
            case SENT -> SUCCESS;
            case QUEUED -> SamTheme.AMBER;
            case NOTHING_HEARD, CANCELLED -> Color.rgb(120, 130, 150);
            case FAILED -> SamTheme.RED;
            default -> RECORDING;
        };
    }

    // ------------------------------------------------------------------ text (allocates; never from onDraw)

    private void relayout() {
        String words = controller.words();
        if (!words.equals(wrappedWordsFrom)) {
            wrappedWordsFrom = words;
            wordLines = TextFit.lastLines(measure, words, 400f, 3, 19f, regular);
        }
        String line = controller.machine().line();
        if (!line.equals(wrappedLineFrom)) {
            wrappedLineFrom = line;
            resultLines = TextFit.firstLines(measure, line, 420f, 2, 20f, regular);
        }
    }

    private String clock(long ms) {
        long second = ms / 1000L;
        if (second != clockSecond) {
            clockSecond = second;
            clockText = (second / 60L) + ":" + (second % 60L < 10L ? "0" : "") + (second % 60L);
        }
        return clockText;
    }

    private String countdown(long remainingMs) {
        long second = (remainingMs + 999L) / 1000L;
        if (second != countdownSecond) {
            countdownSecond = second;
            countdownText = second + " s left";
        }
        return countdownText;
    }
}
