package com.resonolabs.feature.briefing;

import android.app.Activity;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;

import com.resonolabs.runtime.host.BriefingClient;
import com.resonolabs.ui.design.GlassPainter;
import com.resonolabs.ui.design.SamTheme;
import com.resonolabs.ui.design.TextFit;
import com.resonolabs.ui.input.UiInputIntent;

import org.json.JSONObject;

import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;

/**
 * Cards &gt; Morning brief: the headline with "Read it", then Do first, Today, Agents and FYI as rows
 * (verb-first title, the why, the suggested action as a chip). Tap or wheel+press an item for its
 * detail with 2–4 big buttons from its actions: Draft reply (saved as a Gmail draft, never sent),
 * Make task, Block time, Remind me, Open, Done, Dismiss. "Read it" starts a voice turn, only on
 * that tap: the R1 never reads the brief by itself. BACK goes from the detail to the list, then out.
 *
 * <p>Data: the runtime's cached {@code GET /v1/briefing} (re-read every 30 s while shown), or a
 * debug fixture for screenshots. Drawn in the 480x640 logical space; texts are fitted when the data
 * changes, never in onDraw.
 */
public final class BriefingPageView extends View implements AutoCloseable {
    public interface Host {
        /** Leave the page (BACK on the list, or on a detail opened straight from the board). */
        void close();

        /** "Read it": continue in Voice with this request. */
        void say(String text);

        /** An agent item's Open: that T3 thread. */
        void openT3Thread(String threadId);
    }

    private static final float W = 480f, H = 640f;
    private static final float LIST_TOP = 92f;
    private static final float ROW_H = 78f;
    private static final float ROW_GAP = 8f;
    private static final float EYEBROW_H = 34f;
    private static final float BUTTON_H = 64f;
    private static final long REFRESH_MS = 30_000L;
    private static final long FEEDBACK_MS = 5_000L;
    public static final int SUCCESS = Color.rgb(96, 214, 160);
    private static final int ROW = 0, EYEBROW = 1, HEADLINE = 2, FOOTER = 3, EMPTY = 4;

    private static final class Row {
        int type;
        float top;
        float height;
        Briefing.Item item;
        String title = "";
        String why = "";
        String chip = "";
        float chipWidth;
        int color;
        boolean twoLines;
        String[] lines = new String[0];
    }

    private final Host host;
    private final BriefingClient client = new BriefingClient();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint measure = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final GlassPainter glass = new GlassPainter();
    private final Typeface medium = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    private final Typeface regular = Typeface.create("sans-serif", Typeface.NORMAL);
    private final RectF rect = new RectF();
    /** "Read it" play mark, built once (onDraw never allocates). */
    private final Path play = new Path();
    private final List<Row> rows = new ArrayList<>();
    private final List<Row> focusRows = new ArrayList<>();
    private final List<RectF> buttonRects = new ArrayList<>();
    private final Runnable refresh = this::load;
    private final Runnable expire = this::invalidate;
    private Briefing brief = Briefing.empty();
    private JSONObject fixture;
    private boolean loaded;
    private boolean failed;
    private String subtitle = "";
    private String needsText = "";
    private float contentHeight;
    private float scroll;
    private int focus;
    // Detail.
    private String detailId;
    private boolean detailOnly;
    private int buttonFocus;
    private List<Briefing.Action> buttons = new ArrayList<>();
    private String[] detailTitle = new String[0];
    private String[] detailWhy = new String[0];
    private String[] detailSuggestion = new String[0];
    private String detailEyebrow = "";
    private String[] buttonLabels = new String[0];
    /** The first suggested action is the filled button; the rest are glass. */
    private int filledButton = -1;
    private float detailContentBottom;
    private String feedback = "";
    private String[] feedbackLines = new String[0];
    private int feedbackColor = SamTheme.MUTED;
    private long feedbackUntil;
    private boolean acting;
    private LinearGradient primaryFill;
    private float downX, downY, lastY;
    private boolean dragging;

    public BriefingPageView(Activity activity, Host host) {
        super(activity);
        this.host = host;
        setFocusable(true);
        setContentDescription("Morning brief");
        play.moveTo(-5f, -8f);
        play.lineTo(8f, 0f);
        play.lineTo(-5f, 8f);
        play.close();
    }

    // ------------------------------------------------------------------ data

    public void start() {
        handler.removeCallbacks(refresh);
        handler.post(refresh);
    }

    public void stop() {
        handler.removeCallbacks(refresh);
    }

    /** A fixed runtime view ({@code GET /v1/briefing} shape) instead of the runtime (debug screenshots). */
    public void useFixture(JSONObject view) {
        fixture = view;
        if (view != null) apply(view);
    }

    /** Opens straight into one item's detail (a board row); BACK then closes the page. */
    public void showItem(String itemId) {
        if (itemId == null) return;
        detailId = itemId;
        detailOnly = true;
        buttonFocus = 0;
        layoutDetail();
        invalidate();
    }

    public boolean detailOpen() {
        return detailId != null;
    }

    private void load() {
        handler.removeCallbacks(refresh);
        if (fixture != null) {
            apply(fixture);
        } else {
            client.load(getContext(), new BriefingClient.Callback() {
                @Override public void onResult(JSONObject value) { apply(value); }

                @Override public void onFailure(int httpStatus, String code) {
                    failed = true;
                    if (!loaded) relayout();
                }
            });
        }
        handler.postDelayed(refresh, REFRESH_MS);
    }

    private void apply(JSONObject view) {
        brief = Briefing.parse(view);
        loaded = true;
        failed = false;
        relayout();
    }

    private void relayout() {
        layoutList();
        if (detailId != null) {
            if (brief.find(detailId) == null && loaded) {
                if (detailOnly) { host.close(); return; }
                detailId = null;
            } else {
                layoutDetail();
            }
        }
        invalidate();
    }

    // ------------------------------------------------------------------ input

    public boolean onInput(UiInputIntent input) {
        if (detailId != null) {
            switch (input) {
                case BACK -> {
                    if (detailOnly) return false;
                    closeDetail();
                }
                case NEXT -> moveButton(1);
                case PREVIOUS -> moveButton(-1);
                case ACTIVATE -> { if (!buttons.isEmpty()) press(buttons.get(buttonFocus)); }
                default -> { return false; }
            }
            return true;
        }
        switch (input) {
            case BACK -> { return false; }
            case NEXT -> moveFocus(1);
            case PREVIOUS -> moveFocus(-1);
            case ACTIVATE -> activateFocus();
            default -> { return false; }
        }
        return true;
    }

    private void moveFocus(int delta) {
        if (focusRows.isEmpty()) return;
        focus = Math.floorMod(focus + delta, focusRows.size());
        Row row = focusRows.get(focus);
        float viewport = H - LIST_TOP - 12f;
        if (row.top - scroll < 0f) scroll = Math.max(0f, row.top - 8f);
        else if (row.top + row.height - scroll > viewport) scroll = row.top + row.height - viewport + 8f;
        clampScroll();
        invalidate();
    }

    private void activateFocus() {
        if (focusRows.isEmpty()) return;
        Row row = focusRows.get(focus);
        if (row.type == HEADLINE) readIt();
        else if (row.item != null) openDetail(row.item.id);
    }

    private void moveButton(int delta) {
        if (buttons.isEmpty()) return;
        buttonFocus = Math.floorMod(buttonFocus + delta, buttons.size());
        invalidate();
    }

    private void openDetail(String id) {
        detailId = id;
        detailOnly = false;
        buttonFocus = 0;
        feedback = "";
        layoutDetail();
        invalidate();
    }

    private void closeDetail() {
        detailId = null;
        feedback = "";
        invalidate();
    }

    private void readIt() {
        if (brief.available) host.say("Read me my morning brief.");
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        float x = event.getX() * W / Math.max(1f, getWidth());
        float y = event.getY() * H / Math.max(1f, getHeight());
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN -> { downX = x; downY = y; lastY = y; dragging = false; }
            case MotionEvent.ACTION_MOVE -> {
                if (detailId == null && (dragging || Math.abs(y - downY) > 12f)) {
                    dragging = true;
                    scroll += lastY - y;
                    clampScroll();
                    invalidate();
                }
                lastY = y;
            }
            case MotionEvent.ACTION_UP -> {
                if (!dragging && Math.abs(x - downX) < 24f && Math.abs(y - downY) < 24f) tap(x, y);
                dragging = false;
            }
            default -> { }
        }
        return true;
    }

    private void tap(float x, float y) {
        if (detailId != null) {
            for (int i = 0; i < buttonRects.size(); i++) {
                RectF button = buttonRects.get(i);
                if (x >= button.left - 6f && x <= button.right + 6f && y >= button.top - 6f && y <= button.bottom + 6f) {
                    buttonFocus = i;
                    press(buttons.get(i));
                    return;
                }
            }
            return;
        }
        if (y < LIST_TOP) {
            if (x >= 396f) {
                feedback("Checking with your Mac…", SamTheme.MUTED);
                if (fixture == null) client.refresh(getContext(), new BriefingClient.Callback() {
                    @Override public void onResult(JSONObject value) { handler.postDelayed(refresh, 3_000L); }
                    @Override public void onFailure(int httpStatus, String code) { }
                });
            }
            return;
        }
        float contentY = y - LIST_TOP + scroll;
        for (int i = 0; i < focusRows.size(); i++) {
            Row row = focusRows.get(i);
            if (contentY >= row.top && contentY <= row.top + row.height) {
                focus = i;
                if (row.type == HEADLINE) {
                    if (contentY >= row.top + row.height - 56f && x <= 240f) readIt();
                } else if (row.item != null) {
                    openDetail(row.item.id);
                }
                invalidate();
                return;
            }
        }
    }

    // ------------------------------------------------------------------ actions

    private void press(Briefing.Action action) {
        Briefing.Item item = brief.find(detailId);
        if (item == null || acting) return;
        if ("open".equals(action.type) && !item.threadId.isEmpty()) {
            host.openT3Thread(item.threadId);
            return;
        }
        acting = true;
        feedback("draft_reply".equals(action.type) ? "Writing the draft on your Mac…" : "Working…", SamTheme.MUTED);
        if (fixture != null) {
            handler.postDelayed(() -> {
                acting = false;
                fixture = Briefing.withItemState(fixture, item.id, stateAfter(action.type, item.state));
                apply(fixture);
                feedback(fixtureSay(action.type), SUCCESS);
            }, 500L);
            return;
        }
        client.act(getContext(), item.id, action.type, new BriefingClient.Callback() {
            @Override public void onResult(JSONObject value) {
                acting = false;
                boolean ok = value.optBoolean("ok", true);
                JSONObject open = value.optJSONObject("open");
                String thread = open == null ? "" : open.optString("t3Thread", "");
                if (!thread.isEmpty()) host.openT3Thread(thread);
                String say = value.optString("say", "");
                feedback(say.isEmpty() ? (ok ? "Done." : "That didn't work.") : say, ok ? SUCCESS : SamTheme.AMBER);
                load();
            }

            @Override public void onFailure(int httpStatus, String code) {
                acting = false;
                feedback(httpStatus == 404 ? "That item is no longer in the brief."
                        : httpStatus == 0 ? "The R1's assistant isn't ready. Try again."
                        : "That didn't work. Try it from your phone.", SamTheme.AMBER);
            }
        });
    }

    private void feedback(String text, int color) {
        feedback = text == null ? "" : text;
        feedbackColor = color;
        feedbackUntil = SystemClock.uptimeMillis() + FEEDBACK_MS;
        feedbackLines = TextFit.firstLines(measure, feedback, 404f, 2, 17f, medium);
        handler.removeCallbacks(expire);
        handler.postDelayed(expire, FEEDBACK_MS + 50L);
        invalidate();
    }

    private static String stateAfter(String action, String current) {
        return switch (action) {
            case "draft_reply" -> "drafted";
            case "make_task" -> "tasked";
            case "block_time" -> "blocked";
            case "remind" -> "snoozed";
            case "done" -> "done";
            case "dismiss" -> "dismissed";
            default -> current;
        };
    }

    private static String fixtureSay(String action) {
        return switch (action) {
            case "draft_reply" -> "Saved as a draft in Gmail. Open it on your phone to send.";
            case "make_task" -> "Started a T3 task for it.";
            case "block_time" -> "Blocked time on your calendar.";
            case "remind" -> "I'll bring it back later.";
            case "open" -> "Opened it on your Mac.";
            case "done" -> "Marked done.";
            default -> "Dismissed.";
        };
    }

    // ------------------------------------------------------------------ layout (allocates; data changes only)

    private void layoutList() {
        rows.clear();
        focusRows.clear();
        ZoneId zone = ZoneId.systemDefault();
        String built = brief.builtAt(zone);
        int open = brief.openCount();
        if (!loaded) subtitle = failed ? "Unavailable right now" : "Loading…";
        else if (!brief.configured) subtitle = "Connect your Mac to get one";
        else if (!brief.available) subtitle = "off".equals(brief.status) ? "Update the Mac bridge" : "Not ready yet";
        else subtitle = built.isEmpty() ? (open == 0 ? "All handled" : "Today")
                : "Built " + built + (open == 0 ? " · All handled" : "");
        needsText = brief.needsYou > 0 ? brief.needsYou + (brief.needsYou == 1 ? " needs you" : " need you") : "";
        float y = 4f;
        if (!brief.available) {
            Row empty = add(EMPTY, y, 300f);
            empty.lines = TextFit.firstLines(measure, emptyText(), 380f, 3, 19f, regular);
            contentHeight = y + empty.height;
            return;
        }
        Row headline = add(HEADLINE, y, 0f);
        headline.lines = TextFit.firstLines(measure, brief.headline.isEmpty() ? "Your morning brief" : brief.headline,
                404f, 3, 20f, medium);
        headline.height = 30f + headline.lines.length * 27f + 62f;
        focusRows.add(headline);
        y += headline.height + 14f;
        for (Briefing.Section section : brief.sections) {
            if (section.items.isEmpty()) continue;
            Row eyebrow = add(EYEBROW, y, EYEBROW_H);
            eyebrow.title = section.title.toUpperCase(java.util.Locale.ROOT);
            eyebrow.color = accent(section.id);
            y += EYEBROW_H;
            for (Briefing.Item item : section.items) {
                Row row = add(ROW, y, ROW_H);
                row.item = item;
                row.color = accent(section.id);
                row.chip = TextFit.line(measure, item.chip(), 130f, 14f, medium);
                row.chipWidth = row.chip.isEmpty() ? 0f : measure.measureText(row.chip) + 26f;
                float besideChip = 446f - (row.chipWidth > 0f ? row.chipWidth + 12f : 0f);
                String why = item.why;
                if (item.conflict) why = why.isEmpty() ? "Conflict" : "Conflict · " + why;
                if (!item.account.isEmpty() && "email".equals(item.kind)) why = why.isEmpty() ? item.account
                        : why + " · " + item.account;
                // With a why line the title gets the full width and the chip sits beside the why.
                row.twoLines = !why.isEmpty();
                row.title = TextFit.line(measure, item.title, (row.twoLines ? 446f : besideChip) - 64f, 19f, medium);
                row.why = TextFit.line(measure, why, besideChip - 64f, 15f, regular);
                focusRows.add(row);
                y += ROW_H + ROW_GAP;
            }
            y += 6f;
        }
        if (!brief.footer.isEmpty()) {
            Row footer = add(FOOTER, y, 40f);
            footer.title = TextFit.line(measure, brief.footer, 420f, 13f, regular);
            y += footer.height;
        }
        contentHeight = y + 16f;
        focus = Math.min(focus, Math.max(0, focusRows.size() - 1));
        clampScroll();
    }

    private String emptyText() {
        if (!loaded) return failed ? "The R1's assistant isn't answering right now." : "Loading your morning brief…";
        if (!brief.configured) return "Connect the Mac bridge in Settings. Your Mac builds the brief from your email "
                + "and calendar each morning.";
        if ("off".equals(brief.status)) return "The bridge on your Mac is too old for the morning brief.";
        return "Today's brief isn't ready yet. It is built by 7:00 on your Mac.";
    }

    private void layoutDetail() {
        Briefing.Item item = brief.find(detailId);
        if (item == null) return;
        String section = Briefing.defaultSectionTitle(item.section);
        detailEyebrow = section + (item.account.isEmpty() ? "" : " · " + item.account)
                + (item.open() ? "" : " · " + item.chip());
        detailTitle = TextFit.firstLines(measure, item.title, 404f, 3, 26f, medium);
        String why = item.why;
        if (!item.time.isEmpty()) why = why.isEmpty() ? item.time : item.time + " · " + why;
        if (item.conflict) why = why.isEmpty() ? "Overlaps another event" : why + " · overlaps another event";
        detailWhy = TextFit.firstLines(measure, why, 404f, 3, 18f, regular);
        detailSuggestion = item.suggestion.isEmpty() ? new String[0]
                : TextFit.firstLines(measure, "Suggested: " + item.suggestion, 404f, 2, 17f, regular);
        detailContentBottom = 132f + detailTitle.length * 34f + 14f + detailWhy.length * 25f
                + (detailSuggestion.length > 0 ? 8f + detailSuggestion.length * 24f : 0f);
        buttons = item.buttons();
        buttonFocus = Math.min(buttonFocus, Math.max(0, buttons.size() - 1));
        filledButton = -1;
        for (int i = 0; i < buttons.size() && filledButton < 0; i++) if (buttons.get(i).primary()) filledButton = i;
        buttonRects.clear();
        int count = buttons.size();
        int rowsOfButtons = (count + 1) / 2;
        float top = 628f - rowsOfButtons * BUTTON_H - (rowsOfButtons - 1) * 10f;
        buttonLabels = new String[count];
        for (int i = 0; i < count; i++) {
            int line = i / 2;
            boolean full = count % 2 == 1 && i == count - 1;
            float left = full || i % 2 == 0 ? 18f : 246f;
            float right = full || i % 2 == 1 ? 462f : 234f;
            float buttonTop = top + line * (BUTTON_H + 10f);
            buttonRects.add(new RectF(left, buttonTop, right, buttonTop + BUTTON_H));
            buttonLabels[i] = TextFit.line(measure, buttons.get(i).label, right - left - 24f, 20f, medium);
        }
        primaryFill = new LinearGradient(0f, 0f, 0f, BUTTON_H, SamTheme.withAlpha(SamTheme.ORB_BLUE, 240),
                SamTheme.withAlpha(SamTheme.ORB_BLUE, 195), Shader.TileMode.CLAMP);
    }

    private Row add(int type, float top, float height) {
        Row row = new Row();
        row.type = type;
        row.top = top;
        row.height = height;
        rows.add(row);
        return row;
    }

    private void clampScroll() {
        float max = Math.max(0f, contentHeight - (H - LIST_TOP));
        scroll = Math.max(0f, Math.min(max, scroll));
    }

    private static int accent(String section) {
        return switch (section == null ? "" : section) {
            case "do_first" -> SamTheme.AMBER;
            case "today" -> SamTheme.PINK;
            case "agents" -> SamTheme.ORB_PALE;
            default -> SamTheme.MUTED;
        };
    }

    // ------------------------------------------------------------------ drawing (no allocation)

    @Override protected void onDraw(Canvas canvas) {
        canvas.save();
        canvas.scale(getWidth() / W, getHeight() / H);
        SamTheme.background(canvas, paint, W, H, 420f, 20f, 260f, SamTheme.AMBER);
        SamTheme.text(canvas, paint, "Morning brief", 64f, 52f, 30f, SamTheme.INK, Paint.Align.LEFT, true);
        boolean showFeedback = !feedback.isEmpty() && SystemClock.uptimeMillis() < feedbackUntil;
        if (detailId != null) drawDetail(canvas, showFeedback);
        else {
            String sub = showFeedback && !acting && feedbackColor == SamTheme.MUTED ? feedback : subtitle;
            SamTheme.text(canvas, paint, sub, 65f, 76f, 15f, SamTheme.MUTED, Paint.Align.LEFT, false);
            drawRefresh(canvas);
            canvas.save();
            canvas.clipRect(0f, LIST_TOP, W, H);
            canvas.translate(0f, LIST_TOP - scroll);
            drawList(canvas);
            canvas.restore();
        }
        canvas.restore();
    }

    private void drawRefresh(Canvas canvas) {
        float cx = 436f, cy = 46f;
        glass.draw(canvas, paint, cx - 24f, cy - 24f, cx + 24f, cy + 24f, 24f, false);
        rect.set(cx - 10f, cy - 10f, cx + 10f, cy + 10f);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.4f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.withAlpha(SamTheme.INK, 210));
        canvas.drawArc(rect, -60f, 290f, false, paint);
        paint.setStyle(Paint.Style.FILL);
        paint.setStrokeCap(Paint.Cap.BUTT);
        canvas.drawCircle(cx + 5f, cy - 9f, 3.4f, paint);
    }

    private void drawList(Canvas canvas) {
        for (int i = 0; i < rows.size(); i++) {
            Row row = rows.get(i);
            if (row.top + row.height < scroll - 10f || row.top > scroll + H) continue;
            boolean focused = !focusRows.isEmpty() && focusRows.get(focus) == row;
            switch (row.type) {
                case HEADLINE -> drawHeadline(canvas, row, focused);
                case EYEBROW -> {
                    paint.setColor(row.color);
                    canvas.drawCircle(32f, row.top + 20f, 4f, paint);
                    paint.setLetterSpacing(0.14f);
                    SamTheme.text(canvas, paint, row.title, 44f, row.top + 25f, 13f, SamTheme.withAlpha(SamTheme.INK, 190),
                            Paint.Align.LEFT, true);
                    paint.setLetterSpacing(0f);
                }
                case ROW -> drawRow(canvas, row, focused);
                case FOOTER -> SamTheme.text(canvas, paint, row.title, 240f, row.top + 24f, 13f,
                        SamTheme.withAlpha(SamTheme.MUTED, 190), Paint.Align.CENTER, false);
                default -> drawEmpty(canvas, row);
            }
        }
    }

    private void drawHeadline(Canvas canvas, Row row, boolean focused) {
        rect.set(18f, row.top, 462f, row.top + row.height);
        glass.draw(canvas, paint, rect, 24f, focused);
        float y = row.top + 38f;
        for (String line : row.lines) {
            SamTheme.text(canvas, paint, line, 38f, y, 20f, SamTheme.INK, Paint.Align.LEFT, true);
            y += 27f;
        }
        // "Read it" pill: a voice turn, only when tapped.
        float top = row.top + row.height - 54f;
        rect.set(36f, top, 176f, top + 40f);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(SamTheme.withAlpha(SamTheme.ORB_BLUE, 220));
        canvas.drawRoundRect(rect, 20f, 20f, paint);
        paint.setColor(SamTheme.INK);
        canvas.save();
        canvas.translate(60f, top + 20f);
        canvas.drawPath(play, paint);
        canvas.restore();
        SamTheme.text(canvas, paint, "Read it", 80f, top + 27f, 18f, SamTheme.INK, Paint.Align.LEFT, true);
        if (!needsText.isEmpty()) {
            SamTheme.text(canvas, paint, needsText, 442f, top + 27f, 16f, SamTheme.AMBER, Paint.Align.RIGHT, true);
        }
    }

    private void drawRow(Canvas canvas, Row row, boolean focused) {
        Briefing.Item item = row.item;
        boolean open = item.open();
        rect.set(18f, row.top, 462f, row.top + row.height);
        glass.draw(canvas, paint, rect, 20f, focused);
        float mid = row.top + row.height / 2f;
        if (open) {
            paint.setColor(row.color);
            canvas.drawCircle(42f, mid, 6f, paint);
        } else {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2.6f);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setColor(SUCCESS);
            canvas.drawLine(35f, mid, 40f, mid + 5f, paint);
            canvas.drawLine(40f, mid + 5f, 50f, mid - 6f, paint);
            paint.setStrokeCap(Paint.Cap.BUTT);
            paint.setStyle(Paint.Style.FILL);
        }
        int ink = open ? SamTheme.INK : SamTheme.withAlpha(SamTheme.INK, 120);
        SamTheme.text(canvas, paint, row.title, 64f, row.twoLines ? row.top + 32f : mid + 7f, 19f, ink,
                Paint.Align.LEFT, true);
        if (row.twoLines) {
            SamTheme.text(canvas, paint, row.why, 64f, row.top + 59f, 15f,
                    open ? SamTheme.MUTED : SamTheme.withAlpha(SamTheme.MUTED, 130), Paint.Align.LEFT, false);
        }
        if (row.chipWidth > 0f) {
            float chipMid = row.twoLines ? row.top + 54f : mid;
            rect.set(446f - row.chipWidth, chipMid - 14f, 446f, chipMid + 14f);
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(open ? SamTheme.withAlpha(row.color, 46) : SamTheme.withAlpha(SUCCESS, 34));
            canvas.drawRoundRect(rect, 14f, 14f, paint);
            SamTheme.text(canvas, paint, row.chip, rect.centerX(), chipMid + 5f, 14f,
                    open ? ChipColors.pale(row.color) : SUCCESS, Paint.Align.CENTER, true);
        }
    }

    private void drawEmpty(Canvas canvas, Row row) {
        paint.setColor(SamTheme.withAlpha(SamTheme.AMBER, 60));
        canvas.drawCircle(240f, row.top + 90f, 44f, paint);
        paint.setColor(SamTheme.AMBER);
        canvas.drawCircle(240f, row.top + 90f, 18f, paint);
        float y = row.top + 180f;
        for (String line : row.lines) {
            SamTheme.text(canvas, paint, line, 240f, y, 19f, SamTheme.MUTED, Paint.Align.CENTER, false);
            y += 27f;
        }
    }

    private void drawDetail(Canvas canvas, boolean showFeedback) {
        Briefing.Item item = brief.find(detailId);
        SamTheme.text(canvas, paint, detailEyebrow, 65f, 76f, 15f, SamTheme.MUTED, Paint.Align.LEFT, false);
        if (item == null) return;
        float limit = buttonRects.isEmpty() ? 610f : buttonRects.get(0).top - 14f;
        float wanted = detailContentBottom + 12f + (showFeedback ? 14f + feedbackLines.length * 24f : 0f);
        float panelBottom = Math.min(limit, Math.max(250f, wanted));
        rect.set(18f, 96f, 462f, panelBottom);
        glass.draw(canvas, paint, rect, 24f, false);
        paint.setColor(accent(item.section));
        canvas.drawRoundRect(18f, 120f, 23f, 150f, 2.5f, 2.5f, paint);
        float y = 132f;
        for (String line : detailTitle) {
            SamTheme.text(canvas, paint, line, 38f, y + 12f, 26f, SamTheme.INK, Paint.Align.LEFT, true);
            y += 34f;
        }
        y += 14f;
        for (String line : detailWhy) {
            SamTheme.text(canvas, paint, line, 38f, y, 18f, SamTheme.MUTED, Paint.Align.LEFT, false);
            y += 25f;
        }
        if (detailSuggestion.length > 0) y += 8f;
        for (String line : detailSuggestion) {
            SamTheme.text(canvas, paint, line, 38f, y, 17f, SamTheme.ORB_PALE, Paint.Align.LEFT, false);
            y += 24f;
        }
        if (showFeedback) {
            float fy = panelBottom - 20f - (feedbackLines.length - 1) * 24f;
            for (String line : feedbackLines) {
                SamTheme.text(canvas, paint, line, 38f, fy, 17f, feedbackColor, Paint.Align.LEFT, true);
                fy += 24f;
            }
        }
        for (int i = 0; i < buttonRects.size(); i++) {
            RectF button = buttonRects.get(i);
            boolean focused = i == buttonFocus;
            if (i == filledButton) {
                canvas.save();
                canvas.translate(button.left, button.top);
                paint.setStyle(Paint.Style.FILL);
                paint.setColor(Color.BLACK);
                paint.setShader(primaryFill);
                canvas.drawRoundRect(0f, 0f, button.width(), button.height(), 22f, 22f, paint);
                paint.setShader(null);
                canvas.restore();
                if (acting) {
                    paint.setColor(SamTheme.withAlpha(SamTheme.BACKGROUND, 110));
                    canvas.drawRoundRect(button, 22f, 22f, paint);
                }
            } else {
                glass.draw(canvas, paint, button, 22f, false);
            }
            if (focused) {
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(2.4f);
                paint.setColor(SamTheme.withAlpha(SamTheme.ORB_PALE, 220));
                rect.set(button.left - 4f, button.top - 4f, button.right + 4f, button.bottom + 4f);
                canvas.drawRoundRect(rect, 26f, 26f, paint);
                paint.setStyle(Paint.Style.FILL);
            }
            SamTheme.text(canvas, paint, buttonLabels[i], button.centerX(), button.centerY() + 7f, 20f, SamTheme.INK,
                    Paint.Align.CENTER, true);
        }
    }

    @Override public void close() {
        stop();
        handler.removeCallbacksAndMessages(null);
        client.close();
    }

    /** Pale tints for chip text on dark glass (a lighter shade of the section colour). */
    private static final class ChipColors {
        static int pale(int color) {
            return Color.rgb(Color.red(color) + (255 - Color.red(color)) * 2 / 5,
                    Color.green(color) + (255 - Color.green(color)) * 2 / 5,
                    Color.blue(color) + (255 - Color.blue(color)) * 2 / 5);
        }
    }
}
