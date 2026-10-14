package com.resonolabs.feature.briefing;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.json.JSONObject;
import org.junit.Test;

import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;

public final class BriefingTest {
    private static final ZoneId NEW_YORK = ZoneId.of("America/New_York");
    private static final long EIGHT_AM = ZonedDateTime.of(2026, 10, 14, 8, 0, 0, 0, NEW_YORK).toInstant().toEpochMilli();

    private static JSONObject view(String date, String state) throws Exception {
        return new JSONObject("{\"configured\":true,\"available\":true,\"status\":\"ready\",\"today\":\"2026-10-14\","
                + "\"morning\":true,\"briefing\":{\"date\":\"" + date + "\",\"revision\":3,"
                + "\"headline\":\"2 things need you\",\"updatedAt\":\"2026-10-14T11:01:00Z\",\"needsYou\":2,"
                + "\"sections\":[{\"id\":\"do_first\",\"title\":\"Do first\",\"items\":["
                + "{\"id\":\"bi_dana\",\"kind\":\"email\",\"title\":\"Reply to Dana\",\"why\":\"Due Friday\","
                + "\"state\":\"" + state + "\",\"actions\":[{\"type\":\"draft_reply\",\"label\":\"Draft reply\"},"
                + "{\"type\":\"remind\",\"label\":\"Remind 4 pm\"}]},"
                + "{\"id\":\"bi_pay\",\"kind\":\"email\",\"title\":\"Payout failed\",\"actions\":[{\"type\":\"open\"}]}]},"
                + "{\"id\":\"today\",\"items\":[{\"id\":\"bi_standup\",\"kind\":\"event\",\"title\":\"Standup\","
                + "\"time\":\"10:00\",\"conflict\":true,\"actions\":[]}]},"
                + "{\"id\":\"agents\",\"items\":[{\"id\":\"bi_agent\",\"kind\":\"agent\",\"title\":\"Fix login\","
                + "\"threadId\":\"t-1\",\"actions\":[{\"type\":\"open\",\"label\":\"Open\"}]}]}]}}");
    }

    @Test public void parsesSectionsItemsAndButtons() throws Exception {
        Briefing brief = Briefing.parse(view("2026-10-14", "open"));
        assertTrue(brief.available);
        assertEquals(List.of("bi_dana", "bi_pay", "bi_standup", "bi_agent"), ids(brief));
        assertEquals("Today", brief.sections.get(1).title);
        Briefing.Item dana = brief.find("bi_dana");
        assertEquals("Draft reply", dana.chip());
        assertEquals(List.of("draft_reply", "remind", "done", "dismiss"), types(dana.buttons()));
        assertEquals(List.of("open", "done", "dismiss"), types(brief.find("bi_pay").buttons()));
        assertEquals("Open", brief.find("bi_pay").actions.get(0).label);
        assertEquals("10:00", brief.find("bi_standup").chip());
        assertTrue(brief.find("bi_standup").conflict);
        assertEquals("t-1", brief.find("bi_agent").threadId);
        assertEquals(4, brief.openCount());
        assertEquals(2, brief.doFirst().size());
        assertEquals("7:01", brief.builtAt(NEW_YORK));
        assertNull(brief.find("nope"));
    }

    @Test public void handledItemsShowTheirStateAndLoseTheirSuggestions() throws Exception {
        Briefing brief = Briefing.parse(view("2026-10-14", "drafted"));
        Briefing.Item dana = brief.find("bi_dana");
        assertTrue(dana.open());
        assertEquals("Drafted", dana.chip());
        assertEquals("no second draft once it is drafted", List.of("remind", "done", "dismiss"), types(dana.buttons()));
        Briefing done = Briefing.parse(view("2026-10-14", "done"));
        assertFalse(done.find("bi_dana").open());
        assertEquals(List.of("draft_reply", "remind"), types(done.find("bi_dana").buttons()));
        assertEquals(1, done.doFirst().size());
    }

    @Test public void theBoardShowsItOnlyThisMorningWhileSomethingIsOpen() throws Exception {
        Briefing brief = Briefing.parse(view("2026-10-14", "open"));
        assertTrue(brief.showOnBoard(EIGHT_AM, NEW_YORK, false));
        assertFalse("before 05:00", brief.showOnBoard(EIGHT_AM - 4 * 3_600_000L, NEW_YORK, false));
        assertFalse("from noon", brief.showOnBoard(EIGHT_AM + 4 * 3_600_000L, NEW_YORK, false));
        assertFalse("yesterday's brief", Briefing.parse(view("2026-10-13", "open")).showOnBoard(EIGHT_AM, NEW_YORK,
                false));
        assertFalse(Briefing.empty().showOnBoard(EIGHT_AM, NEW_YORK, true));
        assertTrue("fixtures ignore the clock", brief.showOnBoard(EIGHT_AM + 6 * 3_600_000L, NEW_YORK, true));
    }

    @Test public void fixtureActionsChangeOneItemsState() throws Exception {
        JSONObject changed = Briefing.withItemState(view("2026-10-14", "open"), "bi_pay", "dismissed");
        Briefing brief = Briefing.parse(changed);
        assertEquals("dismissed", brief.find("bi_pay").state);
        assertEquals("open", brief.find("bi_dana").state);
    }

    private static List<String> ids(Briefing brief) {
        List<String> out = new ArrayList<>();
        for (Briefing.Item item : brief.items()) out.add(item.id);
        return out;
    }

    private static List<String> types(List<Briefing.Action> actions) {
        List<String> out = new ArrayList<>();
        for (Briefing.Action action : actions) out.add(action.type);
        return out;
    }
}
