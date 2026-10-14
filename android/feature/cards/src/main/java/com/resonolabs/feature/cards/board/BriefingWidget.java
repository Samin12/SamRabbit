package com.resonolabs.feature.cards.board;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;

import com.resonolabs.feature.briefing.Briefing;
import com.resonolabs.runtime.host.BriefingClient;
import com.resonolabs.ui.design.SamTheme;

import org.json.JSONObject;

import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;

/**
 * The morning brief, right under the clock, from 05:00 until noon while something in it is still
 * open (otherwise hidden: the board stays clean in the afternoon and when the Mac has no brief).
 * Header "MORNING BRIEF · 7:01", the one-line headline, then up to three Do-first rows (verb-first
 * title, the why, the suggested action as a chip). The header opens the full page; a row opens
 * that item's detail with its buttons. It only reads the runtime's cache (no wait on the Mac) and
 * never speaks.
 */
public final class BriefingWidget implements BoardWidget {
    private static final int HEADER = 0, HEADLINE = 1, ITEM = 2;
    private static final int MAX_ROWS = 3;
    private static final float PAD = 22f;
    private static final float ROW = 64f;
    private static final float DOT_X = 36f;
    private static final float TEXT_X = 56f;
    private static final int ACCENT = SamTheme.AMBER;

    private static final class Row {
        int type;
        float top;
        float height;
        String id;
        String title = "";
        String why = "";
        String chip = "";
        float chipWidth;
        String[] lines = new String[0];
    }

    private final BoardHost host;
    private final BriefingClient client = new BriefingClient();
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final GlassPanel glass = new GlassPanel();
    private final OrbGlyph headerOrb = new OrbGlyph();
    private final RectF rect = new RectF();
    private final List<Row> rows = new ArrayList<>();
    private final List<Row> focusable = new ArrayList<>();
    private Briefing brief = Briefing.empty();
    private JSONObject view;
    private String fixture = "";
    private boolean inFlight;
    private float width;
    private String summary = "";

    public BriefingWidget(BoardHost host) {
        this.host = host;
    }

    @Override public String id() { return "briefing"; }

    /** The runtime view last read (the full page starts from it in fixture mode). */
    public JSONObject snapshot() {
        return view;
    }

    public boolean fixtureMode() {
        return !fixture.isEmpty();
    }

    // ------------------------------------------------------------- data

    @Override public long refreshIntervalMs() { return 60_000L; }

    @Override public void onShow() {
        String state = host.fixtureState(id());
        if (state.isEmpty()) {
            state = switch (host.fixtureMode()) {
                case FULL -> "full";
                case EMPTY -> "empty";
                case UNCONFIGURED -> "unconfigured";
                default -> "";
            };
        }
        if (!state.equals(fixture)) {
            fixture = state;
            view = null;
            brief = Briefing.empty();
            host.widgetChanged(this);
        }
    }

    @Override public void refresh() {
        if (!fixture.isEmpty()) {
            apply(BoardFixtures.briefing(fixture, System.currentTimeMillis(), ZoneId.systemDefault()));
            return;
        }
        if (inFlight) return;
        inFlight = true;
        client.load(host.context(), new BriefingClient.Callback() {
            @Override public void onResult(JSONObject value) {
                inFlight = false;
                apply(value);
            }

            @Override public void onFailure(int httpStatus, String code) {
                inFlight = false;
            }
        });
    }

    /** After an action on the full page: read the cache again at once. */
    public void reload() {
        refresh();
    }

    private void apply(JSONObject value) {
        view = value;
        brief = Briefing.parse(value);
        host.widgetChanged(this);
    }

    // ------------------------------------------------------------- layout

    @Override public float measure(float width, long nowMs) {
        this.width = width;
        rows.clear();
        focusable.clear();
        if (!brief.showOnBoard(nowMs, ZoneId.systemDefault(), !fixture.isEmpty())) return 0f;
        float y = 0f;
        Row header = add(HEADER, y, 56f);
        y += header.height;
        String built = brief.builtAt(ZoneId.systemDefault());
        int open = brief.openCount();
        String count = brief.needsYou > 0 ? brief.needsYou + (brief.needsYou == 1 ? " needs you" : " need you")
                : open + " to do";
        summary = (built.isEmpty() ? "" : built + " · ") + count;
        Row headline = add(HEADLINE, y, 0f);
        headline.lines = BoardPaint.wrap(paint, brief.headline.isEmpty() ? "Your morning brief" : brief.headline,
                width - 2 * PAD, 2, 18f, BoardPaint.MEDIUM);
        headline.height = 8f + headline.lines.length * 25f;
        y += headline.height;
        List<Briefing.Item> items = brief.doFirst();
        if (items.isEmpty()) {
            items = new ArrayList<>();
            for (Briefing.Item item : brief.items()) if (item.open()) items.add(item);
        }
        int shown = 0;
        for (Briefing.Item item : items) {
            if (shown == MAX_ROWS) break;
            Row row = add(ITEM, y, ROW);
            row.id = item.id;
            row.chip = BoardPaint.fit(paint, item.chip(), 120f, 14f, BoardPaint.MEDIUM);
            row.chipWidth = row.chip.isEmpty() ? 0f : BoardPaint.width(paint, row.chip, 14f, BoardPaint.MEDIUM) + 24f;
            float right = width - PAD - (row.chipWidth > 0f ? row.chipWidth + 10f : 0f);
            row.title = BoardPaint.fit(paint, item.title, right - TEXT_X, 18f, BoardPaint.MEDIUM);
            row.why = BoardPaint.fit(paint, item.why, right - TEXT_X, 14f, BoardPaint.REGULAR);
            y += ROW;
            shown++;
        }
        y += 10f;
        glass.size(width, y, 28f);
        headerOrb.set(31f, 30f, 7f, ACCENT, 2.6f);
        return y;
    }

    private Row add(int type, float top, float height) {
        Row row = new Row();
        row.type = type;
        row.top = top;
        row.height = height;
        rows.add(row);
        if (type != HEADLINE) focusable.add(row);
        return row;
    }

    // ------------------------------------------------------------- drawing

    @Override public void draw(Canvas canvas, long nowMs) {
        glass.draw(canvas, paint, false);
        for (int i = 0; i < rows.size(); i++) {
            Row row = rows.get(i);
            switch (row.type) {
                case HEADER -> drawHeader(canvas);
                case HEADLINE -> {
                    float y = row.top + 18f;
                    for (String line : row.lines) {
                        BoardPaint.text(canvas, paint, line, PAD, y, 18f, SamTheme.INK, Paint.Align.LEFT,
                                BoardPaint.MEDIUM);
                        y += 25f;
                    }
                }
                default -> drawItem(canvas, row, i > 0 && rows.get(i - 1).type == ITEM);
            }
        }
    }

    private void drawHeader(Canvas canvas) {
        headerOrb.draw(canvas, paint);
        BoardPaint.eyebrow(canvas, paint, "MORNING BRIEF", 47f, 36f, 14f, SamTheme.withAlpha(SamTheme.INK, 230),
                Paint.Align.LEFT);
        BoardPaint.text(canvas, paint, summary, width - 42f, 36f, 15f, SamTheme.MUTED, Paint.Align.RIGHT,
                BoardPaint.REGULAR);
        paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(2.2f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setColor(SamTheme.MUTED);
        float cx = width - 28f, cy = 31f;
        canvas.drawLine(cx - 3f, cy - 6f, cx + 3f, cy, paint);
        canvas.drawLine(cx + 3f, cy, cx - 3f, cy + 6f, paint);
        paint.setStrokeCap(Paint.Cap.BUTT);
        paint.setStyle(Paint.Style.FILL);
    }

    private void drawItem(Canvas canvas, Row row, boolean separated) {
        if (separated) {
            paint.setShader(null);
            paint.setColor(SamTheme.LINE);
            canvas.drawRect(TEXT_X, row.top, width - PAD, row.top + 1f, paint);
        }
        float cy = row.top + row.height / 2f;
        paint.setShader(null);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(ACCENT);
        canvas.drawCircle(DOT_X, cy, 5f, paint);
        boolean twoLines = !row.why.isEmpty();
        BoardPaint.text(canvas, paint, row.title, TEXT_X, twoLines ? row.top + 28f : cy + 6f, 18f, SamTheme.INK,
                Paint.Align.LEFT, BoardPaint.MEDIUM);
        if (twoLines) {
            BoardPaint.text(canvas, paint, row.why, TEXT_X, row.top + 50f, 14f, SamTheme.MUTED, Paint.Align.LEFT,
                    BoardPaint.REGULAR);
        }
        if (row.chipWidth > 0f) {
            rect.set(width - PAD - row.chipWidth, cy - 15f, width - PAD, cy + 15f);
            paint.setColor(SamTheme.withAlpha(ACCENT, 44));
            canvas.drawRoundRect(rect, 15f, 15f, paint);
            BoardPaint.text(canvas, paint, row.chip, rect.centerX(), cy + 5f, 14f, OrbGlyph.pale(ACCENT),
                    Paint.Align.CENTER, BoardPaint.MEDIUM);
        }
    }

    // ------------------------------------------------------------- input

    @Override public int focusCount() { return focusable.size(); }

    @Override public void focusBounds(int index, RectF out) {
        Row row = focusable.get(index);
        if (row.type == HEADER) out.set(6f, 4f, width - 6f, row.height - 2f);
        else out.set(6f, row.top + 1f, width - 6f, row.top + row.height - 1f);
    }

    @Override public String focusKey(int index) {
        Row row = focusable.get(index);
        return row.type == HEADER ? "header" : row.id;
    }

    @Override public boolean onTap(float x, float y) {
        for (Row row : rows) {
            if (y < row.top || y >= row.top + row.height) continue;
            host.openBriefing(row.type == ITEM ? row.id : null);
            return true;
        }
        host.openBriefing(null);
        return true;
    }

    @Override public boolean activate(int index) {
        if (index < 0 || index >= focusable.size()) return false;
        Row row = focusable.get(index);
        host.openBriefing(row.type == ITEM ? row.id : null);
        return true;
    }

    @Override public void close() {
        client.close();
    }
}
