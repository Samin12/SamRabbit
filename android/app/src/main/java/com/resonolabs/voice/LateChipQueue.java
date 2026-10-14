package com.resonolabs.voice;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * Voice-note outcomes that arrived while nobody could see them (pure; unit-tested): a note was on
 * screen, the screen was off, another chip was up. Each waits here until HOME can show it as a chip,
 * and its announcement is acknowledged "seen" only then. One chip per capture id (the runtime's
 * {@code capture.routed} and the app's own resend can report the same note). Failures are never
 * pushed out; past {@link #MAX_WAITING} the oldest good news goes first.
 */
final class LateChipQueue {
    static final int MAX_WAITING = 6;
    private static final int REMEMBERED = 32;

    static final class Chip {
        final String captureId;
        final String text;
        final boolean ok;
        /** The announcement to acknowledge once shown (0: none, e.g. the app's own resend). */
        final long announcementId;

        Chip(String captureId, String text, boolean ok, long announcementId) {
            this.captureId = captureId == null ? "" : captureId;
            this.text = text == null ? "" : text;
            this.ok = ok;
            this.announcementId = announcementId;
        }
    }

    private final ArrayDeque<Chip> waiting = new ArrayDeque<>();
    private final LinkedHashSet<String> known = new LinkedHashSet<>();

    /**
     * Queues {@code chip}; returns the announcement ids to acknowledge right away, without a chip:
     * a second report of a note already queued or shown, or good news pushed out by the cap.
     */
    List<Long> add(Chip chip) {
        List<Long> ackNow = new ArrayList<>();
        if (chip.text.isBlank() || (!chip.captureId.isEmpty() && known.contains(chip.captureId))) {
            if (chip.announcementId > 0) ackNow.add(chip.announcementId);
            return ackNow;
        }
        if (!chip.captureId.isEmpty()) {
            known.add(chip.captureId);
            while (known.size() > REMEMBERED) {
                Iterator<String> oldest = known.iterator();
                oldest.next();
                oldest.remove();
            }
        }
        waiting.add(chip);
        while (waiting.size() > MAX_WAITING) {
            Chip dropped = null;
            for (Chip candidate : waiting) {
                if (candidate.ok) {
                    dropped = candidate;
                    break;
                }
            }
            if (dropped == null) break; // only failures: every one is shown
            waiting.remove(dropped);
            if (dropped.announcementId > 0) ackNow.add(dropped.announcementId);
        }
        return ackNow;
    }

    /** The next chip to show (oldest first), or null. */
    Chip next() {
        return waiting.poll();
    }

    boolean isEmpty() {
        return waiting.isEmpty();
    }

    int size() {
        return waiting.size();
    }
}
