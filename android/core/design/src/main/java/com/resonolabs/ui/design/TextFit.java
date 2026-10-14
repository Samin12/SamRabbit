package com.resonolabs.ui.design;

import android.graphics.Paint;
import android.graphics.Typeface;

import java.util.ArrayList;
import java.util.List;

/**
 * Fitting text into the 480x640 pages: one ellipsized line, or word-wrapped lines. Allocates, so
 * pages call it when their data changes and keep the result; never from onDraw.
 */
public final class TextFit {
    private TextFit() {}

    /** One line no wider than {@code maxWidth}, ellipsized. */
    public static String line(Paint paint, String value, float maxWidth, float size, Typeface face) {
        String text = value == null ? "" : value.trim();
        paint.setTextSize(size);
        paint.setTypeface(face);
        paint.setLetterSpacing(0f);
        if (text.isEmpty() || paint.measureText(text) <= maxWidth) return text;
        int count = paint.breakText(text, true, Math.max(0f, maxWidth - paint.measureText("…")), null);
        return text.substring(0, Math.max(0, count)).stripTrailing() + "…";
    }

    /** Every wrapped line (breaks at spaces when it can). */
    public static List<String> wrap(Paint paint, String value, float maxWidth, float size, Typeface face) {
        paint.setTextSize(size);
        paint.setTypeface(face);
        paint.setLetterSpacing(0f);
        List<String> lines = new ArrayList<>();
        String rest = value == null ? "" : value.trim();
        while (!rest.isEmpty()) {
            int count = paint.breakText(rest, true, maxWidth, null);
            if (count < rest.length()) {
                int space = rest.lastIndexOf(' ', Math.max(0, count));
                if (space > 0) count = space;
            }
            lines.add(rest.substring(0, Math.max(1, count)).trim());
            rest = rest.substring(Math.min(rest.length(), Math.max(1, count))).trim();
        }
        return lines;
    }

    /** At most {@code max} lines from the start; the last one is ellipsized when text is left over. */
    public static String[] firstLines(Paint paint, String value, float maxWidth, int max, float size, Typeface face) {
        List<String> lines = wrap(paint, value, maxWidth, size, face);
        if (lines.size() <= max) return lines.toArray(new String[0]);
        String[] head = lines.subList(0, max).toArray(new String[0]);
        head[max - 1] = line(paint, head[max - 1] + " " + lines.get(max), maxWidth, size, face);
        if (!head[max - 1].endsWith("…")) head[max - 1] = line(paint, head[max - 1] + "…", maxWidth, size, face);
        return head;
    }

    /** The last {@code max} lines (newest words), the first led by "…" when earlier text is hidden. */
    public static String[] lastLines(Paint paint, String value, float maxWidth, int max, float size, Typeface face) {
        List<String> lines = wrap(paint, value, maxWidth, size, face);
        if (lines.size() <= max) return lines.toArray(new String[0]);
        String[] tail = lines.subList(lines.size() - max, lines.size()).toArray(new String[0]);
        tail[0] = "…" + tail[0];
        return tail;
    }
}
