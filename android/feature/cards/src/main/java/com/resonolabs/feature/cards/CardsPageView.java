package com.resonolabs.feature.cards;

import com.resonolabs.feature.compose.ComposeSheet;
import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.widget.FrameLayout;

import com.resonolabs.feature.briefing.BriefingPageView;
import com.resonolabs.feature.calendar.CalendarPageView;
import com.resonolabs.feature.cards.board.AgendaWidget;
import com.resonolabs.feature.cards.board.BoardFixtures;
import com.resonolabs.feature.cards.board.BoardHost;
import com.resonolabs.feature.cards.board.BoardWidget;
import com.resonolabs.feature.cards.board.BriefingWidget;
import com.resonolabs.feature.cards.board.ClockWidget;
import com.resonolabs.feature.cards.board.CreationIdentity;
import com.resonolabs.feature.cards.board.CreationsWidget;
import com.resonolabs.feature.cards.board.JournalWidget;
import com.resonolabs.feature.cards.board.LiveWidget;
import com.resonolabs.feature.cards.board.T3Widget;
import com.resonolabs.feature.cards.board.TasksWidget;
import com.resonolabs.feature.cards.board.WidgetBoardView;
import com.resonolabs.feature.genui.GenUiController;
import com.resonolabs.feature.genui.LiveCardsPageView;
import com.resonolabs.feature.tasks.TaskPageView;
import com.resonolabs.runtime.host.CreationCatalogClient;
import com.resonolabs.ui.input.UiInputIntent;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The Cards tab: a glanceable widget board (clock, the morning brief until noon, Up next, T3, Tasks,
 * Live, Journal, Creations). Full Calendar, Tasks, Live and Morning brief pages and Creations open on top of it with the
 * CardsBackButton and the chrome hidden, exactly as the old deck did; T3 threads and Settings
 * open through {@link Links} in the product shell.
 */
public final class CardsPageView extends FrameLayout implements AutoCloseable {
    /** Destinations outside the Cards tab, wired by the product shell (ProductRootView). */
    public interface Links {
        /** The T3 tab's thread list. */
        void openT3();

        /** The T3 tab opened into one thread; BACK from it should come back to the board. */
        void openT3Thread(String threadId);

        /** Settings (Management: calendar, Heptabase, T3 pairing). */
        void openSettings();

        /** A card button's "say" action: start (or continue) a Voice turn with this request. */
        void say(String text);

        /** Other pages a card can open ("runs", "transcript"). */
        default void openPage(String page) { }
    }

    private final Activity activity;
    private final Runnable openVoice;
    private final java.util.function.Consumer<Boolean> creationVisibility;
    private final CreationCatalogClient client = new CreationCatalogClient();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final WidgetBoardView board;
    private final AgendaWidget agenda;
    private final TasksWidget tasksWidget;
    private final CreationsWidget creations;
    private final T3Widget t3Widget;
    private final LiveWidget liveWidget;
    private final JournalWidget journalWidget;
    private final BriefingWidget briefingWidget;
    private final GenUiController genUi;
    private final CardsBackButton back;
    private final Host host = new Host();
    private final java.util.Map<String, String> fixtureStates = new java.util.HashMap<>();
    private Links links;
    private CreationWebViewHost creation;
    private CreationIdentity openCreation;
    private CalendarPageView calendar;
    private TaskPageView tasks;
    private LiveCardsPageView live;
    private BriefingPageView briefing;
    /** The Live page was opened on one card from a board pill: BACK returns to the board. */
    private boolean liveFromPill;
    private android.app.Dialog composer;
    private int generation = -1;
    private JSONObject lastCatalog = new JSONObject();
    private BoardFixtures.Mode fixtureMode = BoardFixtures.Mode.OFF;
    private boolean closed;

    public CardsPageView(Activity activity, Runnable openVoice,
                         java.util.function.Consumer<Boolean> creationVisibility) {
        super(activity);
        this.activity = activity;
        this.openVoice = openVoice;
        this.creationVisibility = creationVisibility;
        board = new WidgetBoardView(activity);
        genUi = new GenUiController(activity, new CardsGenUiHost());
        agenda = new AgendaWidget(host);
        t3Widget = new T3Widget(host);
        tasksWidget = new TasksWidget(host);
        liveWidget = new LiveWidget(host, genUi);
        journalWidget = new JournalWidget(host);
        briefingWidget = new BriefingWidget(host);
        creations = new CreationsWidget(host);
        List<BoardWidget> widgets = new ArrayList<>();
        widgets.add(new ClockWidget(host));
        widgets.add(briefingWidget);   // 05:00-12:00 while the brief has open items
        widgets.add(agenda);
        widgets.add(t3Widget);      // hidden until T3 is paired
        widgets.add(tasksWidget);
        widgets.add(liveWidget);    // hidden while there are no live, pinned or recent cards
        widgets.add(journalWidget);
        widgets.add(creations);
        board.setWidgets(widgets);
        addView(board, match());
        back = new CardsBackButton(activity, this::navigateBack);
        back.setVisibility(GONE);
        addView(back, new LayoutParams(58, 82));
    }

    /** Wires T3, Settings and Voice destinations (ProductRootView). */
    public void setLinks(Links links) {
        this.links = links;
    }

    public void start() {
        BoardFixtures.Mode mode = BoardFixtures.mode(activity);
        if (mode != fixtureMode) {
            fixtureMode = mode;
            creations.setCatalog(lastCatalog);
        }
        fixtureStates.clear();
        board.start();
        handler.removeCallbacks(refresh);
        handler.post(refresh);
        if (calendar != null) calendar.start();
        if (tasks != null) tasks.start();
        if (live != null) live.start();
        if (briefing != null) briefing.start();
    }

    public void stop() {
        handler.removeCallbacks(refresh);
        board.stop();
        if (calendar != null) calendar.stop();
        if (tasks != null) tasks.stop();
        if (live != null) live.stop();
        if (briefing != null) briefing.stop();
        if (composer != null) { composer.dismiss(); composer = null; }
    }

    public boolean onInput(UiInputIntent input) {
        if (input == UiInputIntent.BACK) { navigateBack(); return true; }
        if (calendar != null) { boolean handled=calendar.onInput(input);if(input==UiInputIntent.BACK&&!handled)closeCalendar();return true; }
        if (tasks != null) { boolean handled=tasks.onInput(input);if(input==UiInputIntent.BACK&&!handled)closeTasks();return true; }
        if (briefing != null) { briefing.onInput(input); return true; }
        if (live != null) { live.onInput(input); return true; }
        if (creation != null) return creation.onInput(input);
        board.onInput(input);
        return true;
    }

    private void navigateBack() {
        if (calendar != null) { if (!calendar.onInput(UiInputIntent.BACK)) closeCalendar(); return; }
        if (tasks != null) { if (!tasks.onInput(UiInputIntent.BACK)) closeTasks(); return; }
        if (briefing != null) { if (!briefing.onInput(UiInputIntent.BACK)) closeBriefing(); return; }
        if (live != null) {
            // A card opened from a board pill goes straight back to the board, like a Calendar event.
            if ((liveFromPill && live.detailOpen()) || !live.onInput(UiInputIntent.BACK)) closeLive();
            return;
        }
        if (creation != null) { closeCreation(); return; }
        openVoice.run();
    }

    /** Cards &gt; Live: every live, pinned and recent GenUI card (e.g. from a notification or Voice). */
    public void openLiveCards() {
        openLive(null);
    }

    /** A note to today's Heptabase journal, spoken or typed (no-op when not connected). */
    public void openJournalNote() {
        if (!journalWidget.canWrite() || composer != null) return;
        composer = ComposeSheet.open(activity, new ComposeSheet.Options()
                        .title("Note for today's journal").action("Add to journal").voiceFirst(true),
                journalWidget::submit);
        composer.setOnDismissListener(ignored -> composer = null);
    }

    /**
     * Cards &gt; Morning brief; {@code itemId} opens that item straight away (BACK then returns to the
     * board). "Read it" continues in Voice; an agent item's Open goes to its T3 thread.
     */
    public void openBriefing(String itemId) {
        if (calendar != null || tasks != null || live != null || creation != null) return;
        if (briefing == null) {
            briefing = new BriefingPageView(activity, new BriefingPageView.Host() {
                @Override public void close() { closeBriefing(); }
                @Override public void say(String text) {
                    closeBriefing();
                    if (links != null) links.say(text);
                }
                @Override public void openT3Thread(String threadId) {
                    closeBriefing();
                    if (links != null) links.openT3Thread(threadId);
                }
            });
            if (briefingWidget.fixtureMode()) briefing.useFixture(briefingWidget.snapshot());
            board.setVisibility(GONE);
            addView(briefing, match());
            back.setVisibility(VISIBLE);
            back.bringToFront();
            creationVisibility.accept(true);
            briefing.start();
            briefing.requestFocus();
        }
        if (itemId != null) briefing.showItem(itemId);
    }

    private void closeBriefing() {
        if (briefing == null) return;
        removeView(briefing);
        briefing.close();
        briefing = null;
        showBoard();
        if (!closed) briefingWidget.reload();
    }

    private void openLive(String cardId) {
        if (live == null) {
            if (calendar != null || tasks != null || creation != null || briefing != null) return;
            live = new LiveCardsPageView(activity, genUi);
            board.setVisibility(GONE);
            addView(live, match());
            back.setVisibility(VISIBLE);
            back.bringToFront();
            creationVisibility.accept(true);
            live.start();
            live.requestFocus();
        }
        liveFromPill = cardId != null && live.openCard(cardId);
    }

    private void closeLive() {
        if (live == null) return;
        removeView(live);
        live.close();
        live = null;
        liveFromPill = false;
        showBoard();
    }

    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            client.load(activity, new CreationCatalogClient.Callback() {
                @Override public void onCatalog(JSONObject catalog) {
                    int next = catalog.optInt("generation", -1);
                    if (next != generation) {
                        generation = next;
                        lastCatalog = catalog;
                        creations.setCatalog(catalog);
                        // A generation bump is any catalog change; only close the open Creation when it changed.
                        if (creation != null && !CreationIdentity.stillOffered(openCreation, identities(catalog))) {
                            closeCreation();
                        }
                    }
                }
                @Override public void onFailure() {}
            });
            handler.postDelayed(this, 2000);
        }
    };

    private void openCreation(JSONObject item) {
        if (creation != null) closeCreation();
        if (android.webkit.WebView.getCurrentWebViewPackage() == null) {
            // No WebView provider is selected on this device: constructing one would crash HOME.
            android.util.Log.w("SamCards", "Creation not opened: no WebView provider is available");
            creations.showNotice("No web engine on this R1");
            return;
        }
        try {
            creation = new CreationWebViewHost(activity, client, item, this::closeCreation);
        } catch (RuntimeException error) {
            android.util.Log.w("SamCards", "Creation could not open: " + error.getClass().getSimpleName());
            creation = null;
            creations.showNotice("Couldn't open that");
            return;
        }
        openCreation = identity(item);
        board.setVisibility(GONE);
        float density = getResources().getDisplayMetrics().density;
        LayoutParams params = new LayoutParams(Math.round(240f * density), Math.round(282f * density));
        params.gravity = Gravity.CENTER;
        addView(creation, params);
        back.setVisibility(VISIBLE);
        back.bringToFront();
        creationVisibility.accept(true);
    }

    private void openCalendar() {
        if (calendar != null) return;
        calendar = new CalendarPageView(activity, openVoice, this::closeCalendar);
        if (fixtureMode != BoardFixtures.Mode.OFF) calendar.useFixture(agenda.snapshot());
        board.setVisibility(GONE);
        addView(calendar, match());
        back.setVisibility(VISIBLE);
        back.bringToFront();
        creationVisibility.accept(true);
        calendar.start(); calendar.requestFocus();
    }

    private void openCalendarEvent(JSONObject event) {
        openCalendar();
        if (calendar != null) calendar.showEvent(event);
    }

    private void closeCalendar() {
        if (calendar == null) return;
        removeView(calendar); calendar.close(); calendar=null; showBoard();
    }

    private void openTasks() {
        if (tasks != null) return;
        tasks = new TaskPageView(activity, openVoice);
        if (fixtureMode != BoardFixtures.Mode.OFF) tasks.useFixture(tasksWidget.snapshot());
        board.setVisibility(GONE); addView(tasks, match()); back.setVisibility(VISIBLE); back.bringToFront(); creationVisibility.accept(true); tasks.start(); tasks.requestFocus();
    }

    private void openTask(JSONObject task) {
        openTasks();
        if (tasks != null) tasks.showTask(task);
    }

    private void closeTasks() {
        if (tasks == null) return;
        removeView(tasks); tasks.close(); tasks=null; showBoard();
        if (!closed) tasksWidget.refresh();
    }

    private void closeCreation() {
        if (creation == null) return;
        removeView(creation);
        creation.destroy();
        creation = null;
        openCreation = null;
        showBoard();
    }

    private void showBoard() {
        board.setVisibility(VISIBLE);
        back.setVisibility(GONE);
        creationVisibility.accept(false);
        board.requestFocus();
    }

    private static List<CreationIdentity> identities(JSONObject catalog) {
        JSONArray cards = catalog.optJSONArray("cards");
        if (cards == null) cards = catalog.optJSONArray("creations");
        List<CreationIdentity> result = new ArrayList<>();
        if (cards != null) for (int i = 0; i < cards.length(); i++) {
            JSONObject item = cards.optJSONObject(i);
            if (item != null) result.add(identity(item));
        }
        return result;
    }

    private static CreationIdentity identity(JSONObject item) {
        String source = item.optString("sourceType", "local_archive");
        String entry = "rabbit_qr_link".equals(source) ? item.optString("entryUrl", "") : item.optString("entryAsset", "");
        return new CreationIdentity(item.optString("creationId"), item.optString("contentHash"), entry, source);
    }

    private LayoutParams match() {
        return new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT);
    }

    @Override public void close() {
        closed = true;
        stop();
        closeCreation();
        closeCalendar();
        closeTasks();
        closeLive();
        closeBriefing();
        board.close();
        client.close();
        genUi.close();
    }

    /** Card actions from the Live page and board pills; Voice turns go through {@link Links#say}. */
    private final class CardsGenUiHost implements GenUiController.Host {
        @Override public boolean sendUserText(String text) { return false; }

        @Override public boolean sendSystemNote(String text, boolean respond) { return false; }

        @Override public void open(String page) {
            switch (page == null ? "" : page) {
                case "calendar" -> { closeLive(); openCalendar(); }
                case "tasks" -> { closeLive(); openTasks(); }
                case "briefing" -> { closeLive(); openBriefing(null); }
                case "cards" -> closeLive();
                default -> { if (links != null) links.openPage(page); }
            }
        }

        @Override public void startSessionWith(String text) {
            if (links != null && text != null && !text.isBlank()) links.say(text);
        }

        @Override public void invalidateUi() {
            board.invalidate();
            if (live != null) live.invalidate();
        }

        @Override public void setImmersive(boolean immersive) { }
    }

    /** The board's view of this page. */
    private final class Host implements BoardHost {
        @Override public Context context() { return activity; }
        @Override public BoardFixtures.Mode fixtureMode() { return fixtureMode; }
        @Override public void widgetChanged(BoardWidget widget) { board.widgetChanged(widget); }
        @Override public void openCalendar() { CardsPageView.this.openCalendar(); }
        @Override public void openCalendarEvent(JSONObject event) { CardsPageView.this.openCalendarEvent(event); }
        @Override public void openTasks() { CardsPageView.this.openTasks(); }
        @Override public void openTask(JSONObject task) { CardsPageView.this.openTask(task); }
        @Override public void openCreation(JSONObject item) { CardsPageView.this.openCreation(item); }
        @Override public String fixtureState(String widgetId) {
            return fixtureStates.computeIfAbsent(widgetId, id -> BoardFixtures.state(activity, id));
        }
        @Override public void openT3() { if (links != null) links.openT3(); }
        @Override public void openT3Thread(String threadId) { if (links != null) links.openT3Thread(threadId); }
        @Override public void openLiveCard(String cardId) { openLive(cardId); }
        @Override public void openJournalNote() { CardsPageView.this.openJournalNote(); }
        @Override public void openSettings() { if (links != null) links.openSettings(); }
        @Override public void openBriefing(String itemId) { CardsPageView.this.openBriefing(itemId); }
    }
}
