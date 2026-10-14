package com.resonolabs.feature.cards.board;

import android.content.Context;

import org.json.JSONObject;

/** What a board widget may ask of the Cards page that hosts it. Main thread only. */
public interface BoardHost {
    Context context();

    /** Debug fixture data instead of the runtime (debug builds, {@code debug.sam.widgets.fake}). */
    BoardFixtures.Mode fixtureMode();

    /**
     * Debug-only forced state for one widget ({@code debug.sam.widgets.<id>}, e.g. t3=reauth,
     * journal=reconnect), or "" for none. Read when the tab is shown.
     */
    String fixtureState(String widgetId);

    /** The widget's data or layout changed: re-measure and redraw. */
    void widgetChanged(BoardWidget widget);

    /** Full Calendar page. */
    void openCalendar();

    /** Calendar page opened straight into one event's detail; BACK returns to the board. */
    void openCalendarEvent(JSONObject event);

    /** Full Tasks page. */
    void openTasks();

    /** Tasks page opened straight into one task's detail; BACK returns to the board. */
    void openTask(JSONObject task);

    /** A catalog Creation (local_archive / plugin_card / rabbit_qr_link), opened as before. */
    void openCreation(JSONObject item);

    /** The T3 tab's thread list. */
    void openT3();

    /** The T3 tab opened straight into one thread; BACK returns to the board. */
    void openT3Thread(String threadId);

    /** Cards &gt; Live (every live, pinned and recent GenUI card); {@code cardId} opens that card, null the list. */
    void openLiveCard(String cardId);

    /** The keyboard bar for a typed journal note (sent verbatim to today's Heptabase journal). */
    void openJournalNote();

    /** Settings (where Management lives: connect a calendar, pair T3 again). */
    void openSettings();

    /** The morning brief page; {@code itemId} opens that item's detail (BACK returns to the board), null the list. */
    default void openBriefing(String itemId) { }
}
