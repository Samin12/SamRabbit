package com.resonolabs.feature.cards.board;

import android.content.Context;
import android.content.pm.ApplicationInfo;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;

/**
 * Realistic fake board data for screenshots on a device without a connected calendar. Debug
 * (debuggable) builds only, switched by a system property read each time the tab is shown:
 * {@code adb shell setprop debug.sam.widgets.fake 1} (also {@code empty} or {@code unconfigured}).
 * Shapes match the runtime projections exactly, so the same parsing and drawing code runs.
 *
 * <p>One widget can also be forced into a state while the others stay real:
 * {@code debug.sam.widgets.t3} = reauth | unreachable | starting | hidden,
 * {@code debug.sam.widgets.journal} = connected | reconnect | disconnected | empty, and
 * {@code debug.sam.widgets.briefing} = full | empty | unconfigured | hidden (shown at any hour).
 */
public final class BoardFixtures {
    public enum Mode { OFF, FULL, EMPTY, UNCONFIGURED }

    public static final String PROPERTY = "debug.sam.widgets.fake";
    private static final List<String[]> TASKS = new ArrayList<>();
    private static int journalSent = 3;

    private BoardFixtures() {}

    public static Mode mode(Context context) {
        if ((context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return Mode.OFF;
        String value = property(PROPERTY).trim().toLowerCase(java.util.Locale.ROOT);
        Mode mode = switch (value) {
            case "1", "true", "full" -> Mode.FULL;
            case "empty" -> Mode.EMPTY;
            case "unconfigured" -> Mode.UNCONFIGURED;
            default -> Mode.OFF;
        };
        if (mode == Mode.OFF) synchronized (TASKS) { TASKS.clear(); }
        return mode;
    }

    /** Debug-only per-widget override ({@code debug.sam.widgets.<widgetId>}), or "". */
    public static String state(Context context, String widgetId) {
        if ((context.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return "";
        return property("debug.sam.widgets." + widgetId).trim().toLowerCase(java.util.Locale.ROOT);
    }

    /** {@code GET /v1/t3/threads} shape, or null when T3 is not paired (UNCONFIGURED). */
    public static JSONObject t3(Mode mode, long nowMs) {
        if (mode == Mode.UNCONFIGURED) return null;
        JSONArray threads = new JSONArray();
        int needsYou = 0, working = 0;
        if (mode == Mode.FULL) {
            thread(threads, "fx-t3-deploy", "Deploy the board build to the R1", "SamRabbit", "needs-approval",
                    "Needs approval", null, -1, nowMs - 2 * 60_000L, false);
            thread(threads, "fx-t3-layout", "Pick the layout for finished threads", "SamRabbit", "needs-input",
                    "Has a question", null, -1, nowMs - 6 * 60_000L, false);
            thread(threads, "fx-t3-safari", "Fix the login redirect loop on Safari", "bookedin-web", "working",
                    "Working", "Running tests", 0.55, nowMs - 20_000L, false);
            thread(threads, "fx-t3-journal", "Summarize this week's journal", "Agent Club", "working",
                    "Working", "Reading notes", -1, nowMs - 3 * 60_000L, false);
            thread(threads, "fx-t3-cadence", "Slow the T3 poller when idle", "SamRabbit", "done",
                    "Done", null, -1, nowMs - 12 * 60_000L, true);
            needsYou = 2;
            working = 2;
        }
        thread(threads, "fx-t3-webinar", "Draft the webinar outline", "Workbench", "done", "Done", null, -1,
                nowMs - 2 * 3_600_000L, false);
        thread(threads, "fx-t3-orb", "Make the orb pulse slower while listening", "SamRabbit", "done", "Done",
                null, -1, nowMs - 5 * 3_600_000L, false);
        JSONObject counts = new JSONObject();
        put(counts, "needsYou", needsYou);
        put(counts, "working", working);
        put(counts, "done", threads.length() - needsYou - working);
        put(counts, "error", 0);
        JSONObject value = new JSONObject();
        put(value, "connected", true);
        put(value, "revision", mode == Mode.FULL ? 1001L : 1002L);
        put(value, "updatedAt", Instant.ofEpochMilli(nowMs - 60_000L).toString());
        put(value, "counts", counts);
        put(value, "projects", new JSONArray());
        put(value, "threads", threads);
        return value;
    }

    private static void thread(JSONArray threads, String id, String title, String project, String status,
                               String label, String phase, double progress, long updatedAt, boolean unread) {
        JSONObject thread = new JSONObject();
        put(thread, "id", id);
        put(thread, "projectId", "fx-" + project.toLowerCase(java.util.Locale.ROOT));
        put(thread, "projectTitle", project);
        put(thread, "title", title);
        put(thread, "status", status);
        put(thread, "statusLabel", label);
        put(thread, "updatedAt", Instant.ofEpochMilli(updatedAt).toString());
        put(thread, "completedAt", "done".equals(status) ? Instant.ofEpochMilli(updatedAt).toString() : JSONObject.NULL);
        put(thread, "unread", unread);
        put(thread, "model", "claude-opus-5-5");
        put(thread, "phase", phase == null ? JSONObject.NULL : phase);
        put(thread, "progress", progress < 0 ? JSONObject.NULL : (Object) progress);
        threads.put(thread);
    }

    /**
     * {@code GET /v1/journal/status} shape for a journal fixture state: connected, reconnect,
     * disconnected or empty (connected, nothing today).
     */
    public static JSONObject journal(String state, long nowMs, ZoneId zone) {
        boolean connected = !"disconnected".equals(state);
        boolean reconnect = "reconnect".equals(state);
        boolean empty = "empty".equals(state);
        int sent;
        synchronized (TASKS) { sent = empty ? 0 : reconnect ? 1 : journalSent; }
        int queued = reconnect ? 2 : empty ? 0 : 0;
        JSONObject today = new JSONObject();
        put(today, "date", Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().toString());
        put(today, "sent", connected ? sent : 0);
        put(today, "queued", connected ? queued : 0);
        put(today, "failed", 0);
        JSONObject value = new JSONObject();
        put(value, "connected", connected);
        put(value, "autoSessions", true);
        put(value, "pending", connected ? queued : 0);
        put(value, "failed", 0);
        put(value, "lastSentAt", connected && sent > 0 ? Instant.ofEpochMilli(nowMs - 9 * 60_000L).toString() : JSONObject.NULL);
        put(value, "needsReconnect", reconnect);
        put(value, "today", today);
        return value;
    }

    /**
     * {@code GET /v1/briefing} (runtime view) for {@code debug.sam.widgets.briefing} = full (default
     * in fake mode) | empty (no brief yet) | unconfigured (no Mac) | hidden. Fictional people only.
     */
    public static JSONObject briefing(String state, long nowMs, ZoneId zone) {
        ZonedDateTime now = Instant.ofEpochMilli(nowMs).atZone(zone);
        String today = now.toLocalDate().toString();
        boolean full = "full".equals(state) || "1".equals(state) || "true".equals(state);
        String built = now.withHour(7).withMinute(1).withSecond(0).withNano(0).toInstant().toString();
        String json = "{\"configured\":" + !"unconfigured".equals(state) + ",\"available\":" + full
                + ",\"status\":\"" + (full ? "ready" : "unconfigured".equals(state) ? "unconfigured" : "loading")
                + "\",\"today\":\"" + today + "\",\"morning\":true,\"stale\":false,\"briefing\":" + (!full ? "null"
                : "{\"date\":\"" + today + "\",\"revision\":3,\"status\":\"ready\",\"updatedAt\":\"" + built + "\","
                + "\"headline\":\"3 things need you · 4 meetings, first at 10:00 AM · 1 agent waiting\","
                + "\"spoken\":\"Three things need you this morning.\",\"needsYou\":3,"
                + "\"footer\":\"Skipped 182 promos and newsletters · business 64 · personal 41 read\","
                + "\"sections\":["
                + "{\"id\":\"do_first\",\"title\":\"Do first\",\"items\":["
                + "{\"id\":\"fx-bi-dana\",\"kind\":\"email\",\"account\":\"business\",\"state\":\"open\","
                + "\"title\":\"Reply to Dana: confirm Thu 2 pm\",\"why\":\"Needs the SOW signed by Friday; asked twice\","
                + "\"suggestion\":\"Draft a reply confirming Thursday 2 pm\",\"actions\":[{\"type\":\"draft_reply\","
                + "\"label\":\"Draft reply\"},{\"type\":\"remind\",\"label\":\"Remind 4 pm\"}]},"
                + "{\"id\":\"fx-bi-payout\",\"kind\":\"email\",\"account\":\"business\",\"state\":\"open\","
                + "\"title\":\"Payout failed: update bank details\",\"why\":\"Stripe retries tomorrow at 9 am\","
                + "\"actions\":[{\"type\":\"open\",\"label\":\"Open\"},{\"type\":\"remind\",\"label\":\"Remind 2 pm\"}]},"
                + "{\"id\":\"fx-bi-acme\",\"kind\":\"email\",\"account\":\"personal\",\"state\":\"open\","
                + "\"title\":\"Bug report from Acme: checkout 500s\",\"why\":\"Their customers can't pay since last night\","
                + "\"suggestion\":\"Start a T3 task to find the failing route\",\"actions\":[{\"type\":\"make_task\","
                + "\"label\":\"Make task\"},{\"type\":\"draft_reply\",\"label\":\"Draft reply\"}]}]},"
                + "{\"id\":\"today\",\"title\":\"Today\",\"items\":["
                + "{\"id\":\"fx-bi-standup\",\"kind\":\"event\",\"state\":\"open\",\"title\":\"Standup\",\"time\":\"10:00 AM\","
                + "\"conflict\":true,\"why\":\"Overlaps the dentist\",\"actions\":[{\"type\":\"block_time\",\"label\":\"Block time\"}]},"
                + "{\"id\":\"fx-bi-review\",\"kind\":\"event\",\"state\":\"open\",\"title\":\"Design review\",\"time\":\"1:30 PM\","
                + "\"why\":\"Dana sent the deck for this\",\"actions\":[]}]},"
                + "{\"id\":\"agents\",\"title\":\"Agents\",\"items\":["
                + "{\"id\":\"fx-bi-agent\",\"kind\":\"agent\",\"state\":\"open\",\"threadId\":\"fx-t3-deploy\","
                + "\"title\":\"T3 \\u201cDeploy the board build\\u201d needs approval\",\"why\":\"Wants to reboot the R1\","
                + "\"actions\":[{\"type\":\"open\",\"label\":\"Open\"}]}]},"
                + "{\"id\":\"fyi\",\"title\":\"FYI\",\"items\":["
                + "{\"id\":\"fx-bi-fyi\",\"kind\":\"fyi\",\"state\":\"open\",\"title\":\"Stripe payout of $1,240 arrived\","
                + "\"actions\":[]}]}]}") + "}";
        try {
            return new JSONObject(json);
        } catch (JSONException invalid) {
            return new JSONObject();
        }
    }

    /** Fake {@code POST /v1/journal/notes}. */
    public static JSONObject journalNote(String state, long nowMs, ZoneId zone) {
        boolean queued = "reconnect".equals(state);
        if (!queued) synchronized (TASKS) { journalSent++; }
        JSONObject value = new JSONObject();
        put(value, "recorded", true);
        put(value, "state", queued ? "queued" : "sent");
        put(value, "date", Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate().toString());
        return value;
    }

    /** {@code GET /v1/calendar/upcoming} shape. */
    public static JSONObject calendar(Mode mode, long nowMs, ZoneId zone) {
        JSONArray events = new JSONArray();
        if (mode == Mode.FULL) {
            ZonedDateTime now = Instant.ofEpochMilli(nowMs).atZone(zone);
            ZonedDateTime five = now.truncatedTo(ChronoUnit.MINUTES).withMinute(now.getMinute() / 5 * 5);
            LocalDate today = now.toLocalDate();
            allDay(events, "fx-birthday", "Mom's birthday", today, "Family");
            ZonedDateTime review = five.minusMinutes(25);
            timed(events, "fx-review", "Design review", review, review.plusMinutes(60), "Studio B", "Work",
                    "Walk through the widget board with the team.", "alex@example.com");
            ZonedDateTime lunch = five.plusMinutes(70);
            timed(events, "fx-coffee", "Coffee with Priya", lunch, lunch.plusMinutes(60),
                    "Tartine Bakery, 600 Guerrero St, San Francisco, CA 94110, USA", "Personal", null, null);
            // Real feeds: a raw Zoom link as the location, the same invite on two calendars, a long title.
            ZonedDateTime mastermind = lunch.plusMinutes(90);
            timed(events, "fx-mastermind", "\uD83D\uDE80 7FCEO Mastermind Session: quarterly planning and hot seats",
                    mastermind, mastermind.plusMinutes(60), "https://us02web.zoom.us/j/8681235900", "Work", null, null);
            timed(events, "fx-mastermind-copy", "\uD83D\uDE80 7FCEO Mastermind Session: quarterly planning and hot seats",
                    mastermind, mastermind.plusMinutes(60), "https://us02web.zoom.us/j/8681235900", "Personal", null, null);
            ZonedDateTime oneOnOne = mastermind.plusMinutes(90);
            timed(events, "fx-alex", "1:1 with Alex", oneOnOne, oneOnOne.plusMinutes(30),
                    "Google Meet (instructions in description)", "Work", "Roadmap and hiring.", "alex@example.com");
            ZonedDateTime errand = oneOnOne.plusMinutes(90);
            timed(events, "fx-cleaning", "Pick up dry cleaning", errand, errand.plusMinutes(20), null, "Personal",
                    null, null);
            ZonedDateTime tomorrow = today.plusDays(1).atStartOfDay(zone);
            timed(events, "fx-morning", "\u2600\uFE0F Morning Check", tomorrow.plusHours(7), tomorrow.plusHours(10), null,
                    "Personal", null, null);
            timed(events, "fx-standup", "Team standup", tomorrow.plusHours(9).plusMinutes(30),
                    tomorrow.plusHours(9).plusMinutes(45), null, "Work",
                    "Join with Google Meet: https://meet.google.com/abc-defg-hij", null);
            timed(events, "fx-gym", "Gym", tomorrow.plusHours(12), tomorrow.plusHours(13), "Equinox", "Health", null, null);
            timed(events, "fx-dentist", "Dentist", tomorrow.plusHours(15), tomorrow.plusHours(16),
                    "Dr. Lee · 12 Main St", "Personal", "Bring the insurance card.", null);
            timed(events, "fx-evening", "\uD83C\uDF19 Evening Routine", tomorrow.plusHours(20).plusMinutes(45),
                    tomorrow.plusHours(22).plusMinutes(30), null, "Personal", null, null);
        }
        JSONObject value = new JSONObject();
        put(value, "events", events);
        put(value, "configured", mode != Mode.UNCONFIGURED);
        return value;
    }

    /** {@code GET /v1/tasks/active} shape; completions persist for the process. */
    public static JSONObject tasks(Mode mode) {
        JSONArray tasks = new JSONArray();
        if (mode == Mode.FULL) {
            synchronized (TASKS) {
                if (TASKS.isEmpty()) {
                    String[] texts = {"Book flights to Lisbon", "Reply to Sam about the deck", "Renew passport photos",
                            "Order more coffee beans", "Call the plumber about the sink",
                            "Pick up a birthday gift for Mom", "Back up the R1 photos"};
                    for (int i = 0; i < texts.length; i++) TASKS.add(new String[]{"fx-task-" + i, texts[i]});
                }
                for (String[] task : TASKS) {
                    JSONObject item = new JSONObject();
                    put(item, "taskId", task[0]);
                    put(item, "text", task[1]);
                    put(item, "status", "open");
                    tasks.put(item);
                }
            }
        }
        JSONObject value = new JSONObject();
        put(value, "tasks", tasks);
        return value;
    }

    /** Fake {@code POST /v1/tasks/{id}/complete}. */
    public static JSONObject complete(String taskId) {
        synchronized (TASKS) { TASKS.removeIf(task -> task[0].equals(taskId)); }
        JSONObject task = new JSONObject();
        put(task, "taskId", taskId);
        put(task, "status", "completed");
        JSONObject value = new JSONObject();
        put(value, "task", task);
        put(value, "changed", true);
        return value;
    }

    /** Extra link Creations shown only when the real catalog is empty, so the tiles can be seen. */
    public static JSONArray creations(Mode mode) {
        JSONArray cards = new JSONArray();
        if (mode != Mode.FULL) return cards;
        link(cards, "fx-weather", "Weather", "Forecast for your area", "https://wttr.in/?0", "#5ca2ff");
        link(cards, "fx-wiki", "Rabbit R1 on Wikipedia", "Reference", "https://en.m.wikipedia.org/wiki/Rabbit_r1", "#c792ff");
        link(cards, "fx-news", "Hacker News", "Top stories", "https://news.ycombinator.com/", "#ffd166");
        return cards;
    }

    private static void timed(JSONArray events, String id, String title, ZonedDateTime start, ZonedDateTime end,
                              String location, String calendar, String notes, String organizer) {
        JSONObject event = base(id, title, location, calendar, notes, organizer);
        put(event, "startsAt", start.withZoneSameInstant(ZoneOffset.UTC).toOffsetDateTime().toString());
        put(event, "endsAt", end.withZoneSameInstant(ZoneOffset.UTC).toOffsetDateTime().toString());
        put(event, "allDay", false);
        events.put(event);
    }

    private static void allDay(JSONArray events, String id, String title, LocalDate day, String calendar) {
        JSONObject event = base(id, title, null, calendar, null, null);
        // Same storage convention as the runtime: UTC midnight of the floating date, end exclusive.
        put(event, "startsAt", day.atStartOfDay().atOffset(ZoneOffset.UTC).toString());
        put(event, "endsAt", day.plusDays(1).atStartOfDay().atOffset(ZoneOffset.UTC).toString());
        put(event, "allDay", true);
        events.put(event);
    }

    private static JSONObject base(String id, String title, String location, String calendar, String notes,
                                   String organizer) {
        JSONObject event = new JSONObject();
        put(event, "eventId", id);
        put(event, "calendarAccountId", "fixture");
        put(event, "title", title);
        put(event, "timezone", "UTC");
        // Like the runtime, absent values are JSON null (not omitted).
        put(event, "location", location == null ? JSONObject.NULL : location);
        put(event, "calendar", calendar);
        put(event, "organizer", organizer == null ? JSONObject.NULL : organizer);
        put(event, "description", notes == null ? JSONObject.NULL : notes);
        put(event, "editable", false);
        return event;
    }

    private static void link(JSONArray cards, String id, String title, String description, String url, String accent) {
        JSONObject card = new JSONObject();
        put(card, "creationId", id);
        put(card, "title", title);
        put(card, "description", description);
        put(card, "contentHash", id);
        put(card, "state", "enabled");
        put(card, "generation", 1);
        put(card, "sourceType", "rabbit_qr_link");
        put(card, "accent", accent);
        put(card, "entryUrl", url);
        cards.put(card);
    }

    private static void put(JSONObject target, String key, Object value) {
        try { target.put(key, value); } catch (JSONException ignored) { }
    }

    private static String property(String key) {
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Object value = properties.getMethod("get", String.class, String.class).invoke(null, key, "");
            return value == null ? "" : value.toString();
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            return "";
        }
    }
}
