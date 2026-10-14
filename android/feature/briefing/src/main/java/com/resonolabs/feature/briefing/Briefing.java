package com.resonolabs.feature.briefing;

import org.json.JSONArray;
import org.json.JSONObject;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * The runtime's {@code GET /v1/briefing} view, parsed (pure; unit-tested on the JVM):
 * {@code {configured, available, status, fetchedAt, stale, today, morning, openCount,
 * briefing: {date, revision, headline, spoken, updatedAt, needsYou, footer, sections: [...]}}}.
 *
 * <p>The board shows it from 05:00 until noon while it has open items; the runtime already dropped
 * every action the R1 must never offer (send, approve), so only Draft reply, Make task, Block time,
 * Remind me, Done, Dismiss and Open can appear.
 */
public final class Briefing {
    public static final int MORNING_START_HOUR = 5;
    public static final int MORNING_END_HOUR = 12;

    public static final class Action {
        public final String type;
        public final String label;

        Action(String type, String label) {
            this.type = type;
            this.label = label;
        }

        /** Done, Dismiss: quiet glass buttons; the others are the item's suggestions (filled). */
        public boolean primary() {
            return !"done".equals(type) && !"dismiss".equals(type);
        }
    }

    public static final class Item {
        public final String id;
        public final String kind;
        public final String section;
        public final String title;
        public final String why;
        public final String suggestion;
        public final String account;
        public final String time;
        public final boolean conflict;
        public final String threadId;
        public final String state;
        public final List<Action> actions;

        Item(JSONObject json, String section) {
            id = text(json, "id");
            kind = text(json, "kind");
            this.section = section;
            title = text(json, "title");
            why = text(json, "why");
            suggestion = text(json, "suggestion");
            account = text(json, "account");
            time = text(json, "time");
            conflict = json.optBoolean("conflict", false);
            threadId = text(json, "threadId");
            String value = text(json, "state");
            state = value.isEmpty() ? "open" : value;
            List<Action> parsed = new ArrayList<>();
            JSONArray list = json.optJSONArray("actions");
            for (int i = 0; list != null && i < list.length(); i++) {
                JSONObject action = list.optJSONObject(i);
                if (action == null) continue;
                String type = text(action, "type");
                if (type.isEmpty()) continue;
                String label = text(action, "label");
                parsed.add(new Action(type, label.isEmpty() ? defaultLabel(type) : label));
            }
            actions = Collections.unmodifiableList(parsed);
        }

        public boolean open() {
            return !"done".equals(state) && !"dismissed".equals(state);
        }

        /** The trailing chip on a row: the first suggested action, or the state once handled. */
        public String chip() {
            switch (state) {
                case "drafted": return "Drafted";
                case "tasked": return "Task started";
                case "blocked": return "Blocked";
                case "snoozed": return "Later";
                case "done": return "Done";
                case "dismissed": return "Dismissed";
                default: break;
            }
            if (!time.isEmpty()) return time;
            return actions.isEmpty() ? "" : actions.get(0).label;
        }

        /**
         * The detail page's buttons (2–4): the item's own suggestions first, then Done and Dismiss.
         * A handled item keeps only what still makes sense (Open, Done, Dismiss).
         */
        public List<Action> buttons() {
            List<Action> out = new ArrayList<>();
            for (Action action : actions) {
                if (out.size() == 2) break;
                if (!"done".equals(action.type) && !"dismiss".equals(action.type)) out.add(action);
            }
            if (open()) {
                out.add(new Action("done", "Done"));
                out.add(new Action("dismiss", "Dismiss"));
            }
            return out.size() > 4 ? out.subList(0, 4) : out;
        }
    }

    public static final class Section {
        public final String id;
        public final String title;
        public final List<Item> items;

        Section(String id, String title, List<Item> items) {
            this.id = id;
            this.title = title;
            this.items = items;
        }
    }

    public final boolean configured;
    public final boolean available;
    public final String status;
    public final boolean stale;
    public final String today;
    public final boolean morning;
    public final String date;
    public final int revision;
    public final String headline;
    public final String spoken;
    public final String updatedAt;
    public final int needsYou;
    public final String footer;
    public final List<Section> sections;

    private Briefing(JSONObject view) {
        JSONObject json = view == null ? new JSONObject() : view;
        configured = json.optBoolean("configured", false);
        status = text(json, "status");
        stale = json.optBoolean("stale", false);
        today = text(json, "today");
        morning = json.optBoolean("morning", false);
        JSONObject brief = json.optJSONObject("briefing");
        available = json.optBoolean("available", false) && brief != null;
        JSONObject source = brief == null ? new JSONObject() : brief;
        date = text(source, "date");
        revision = source.optInt("revision", 0);
        headline = text(source, "headline");
        spoken = text(source, "spoken");
        updatedAt = text(source, "updatedAt");
        needsYou = Math.max(0, source.optInt("needsYou", 0));
        footer = text(source, "footer");
        List<Section> parsed = new ArrayList<>();
        JSONArray list = source.optJSONArray("sections");
        for (int i = 0; list != null && i < list.length(); i++) {
            JSONObject section = list.optJSONObject(i);
            if (section == null) continue;
            String id = text(section, "id");
            List<Item> items = new ArrayList<>();
            JSONArray rows = section.optJSONArray("items");
            for (int j = 0; rows != null && j < rows.length(); j++) {
                JSONObject row = rows.optJSONObject(j);
                if (row != null && !text(row, "id").isEmpty() && !text(row, "title").isEmpty()) {
                    items.add(new Item(row, id));
                }
            }
            String title = text(section, "title");
            parsed.add(new Section(id, title.isEmpty() ? defaultSectionTitle(id) : title,
                    Collections.unmodifiableList(items)));
        }
        sections = Collections.unmodifiableList(parsed);
    }

    public static Briefing parse(JSONObject view) {
        return new Briefing(view);
    }

    public static Briefing empty() {
        return new Briefing(null);
    }

    /** Every item, Do first → Today → Agents → FYI. */
    public List<Item> items() {
        List<Item> out = new ArrayList<>();
        for (Section section : sections) out.addAll(section.items);
        return out;
    }

    public Item find(String id) {
        if (id == null) return null;
        for (Item item : items()) if (id.equals(item.id)) return item;
        return null;
    }

    public int openCount() {
        int count = 0;
        for (Item item : items()) if (item.open()) count++;
        return count;
    }

    /** Open items in Do first (the board's rows). */
    public List<Item> doFirst() {
        for (Section section : sections) {
            if ("do_first".equals(section.id)) {
                List<Item> open = new ArrayList<>();
                for (Item item : section.items) if (item.open()) open.add(item);
                return open;
            }
        }
        return Collections.emptyList();
    }

    /**
     * Whether the Cards board shows the brief now: today's brief, between 05:00 and noon in the
     * user's zone, while something is still open. {@code ignoreClock}: debug fixtures for screenshots.
     */
    public boolean showOnBoard(long nowMs, ZoneId zone, boolean ignoreClock) {
        if (!available || openCount() == 0) return false;
        if (ignoreClock) return true;
        ZonedDateTime local = Instant.ofEpochMilli(nowMs).atZone(zone);
        String localToday = local.toLocalDate().toString();
        String expected = today.isEmpty() ? localToday : today;
        if (!expected.equals(date)) return false;
        int hour = local.getHour();
        return hour >= MORNING_START_HOUR && hour < MORNING_END_HOUR;
    }

    /** "7:01" for when the Mac built it (the user's zone), or "". */
    public String builtAt(ZoneId zone) {
        if (updatedAt.isEmpty()) return "";
        try {
            ZonedDateTime local = Instant.parse(updatedAt).atZone(zone);
            int hour = local.getHour() % 12 == 0 ? 12 : local.getHour() % 12;
            return hour + ":" + (local.getMinute() < 10 ? "0" : "") + local.getMinute();
        } catch (DateTimeParseException invalid) {
            return "";
        }
    }

    /** True when {@code date} is the given local day (for "yesterday's" wording). */
    public boolean isFor(LocalDate day) {
        return day != null && day.toString().equals(date);
    }

    /** A copy of a runtime view with one item's state changed (debug fixtures act locally). */
    public static JSONObject withItemState(JSONObject view, String id, String state) {
        try {
            JSONObject copy = new JSONObject(view.toString());
            JSONObject brief = copy.optJSONObject("briefing");
            JSONArray sections = brief == null ? null : brief.optJSONArray("sections");
            for (int i = 0; sections != null && i < sections.length(); i++) {
                JSONArray items = sections.getJSONObject(i).optJSONArray("items");
                for (int j = 0; items != null && j < items.length(); j++) {
                    JSONObject item = items.getJSONObject(j);
                    if (id.equals(item.optString("id"))) item.put("state", state);
                }
            }
            return copy;
        } catch (Exception invalid) {
            return view;
        }
    }

    static String defaultLabel(String type) {
        switch (type) {
            case "draft_reply": return "Draft reply";
            case "make_task": return "Make task";
            case "block_time": return "Block time";
            case "remind": return "Remind me";
            case "done": return "Done";
            case "dismiss": return "Dismiss";
            case "open": return "Open";
            default: return type;
        }
    }

    static String defaultSectionTitle(String id) {
        switch (id) {
            case "do_first": return "Do first";
            case "today": return "Today";
            case "agents": return "Agents";
            case "fyi": return "FYI";
            default: return id;
        }
    }

    static String text(JSONObject json, String key) {
        if (json == null || json.isNull(key)) return "";
        Object value = json.opt(key);
        return value instanceof String string ? string.trim() : "";
    }
}
