package com.resonolabs.voice;

import android.app.Activity;
import android.os.PowerManager;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.widget.FrameLayout;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;

import com.resonolabs.feature.voice.VoicePageView;
import com.resonolabs.feature.settings.SettingsPanelView;
import com.resonolabs.feature.settings.ManagementPairingSource;
import com.resonolabs.feature.cards.CardsPageView;
import com.resonolabs.runtime.host.ManagementOpenAiSource;
import com.resonolabs.feature.camera.CameraHandoffPage;
import com.resonolabs.hardware.motor.R1MotorServiceClient;
import com.resonolabs.ui.input.HardwareInputRouter;
import com.resonolabs.ui.input.UiInputIntent;
import com.resonolabs.feature.backgroundrun.BackgroundRunPanelView;
import com.resonolabs.runtime.host.RuntimeBackgroundRunClient;
import com.resonolabs.runtime.host.RuntimeCreationImportClient;
import com.resonolabs.feature.creationimport.CreationImportView;
import com.resonolabs.feature.t3.T3PageView;
import com.resonolabs.feature.genui.GenCard;
import com.resonolabs.feature.genui.LiveBinding;
import com.resonolabs.feature.genui.T3AnnouncementCards;
import com.resonolabs.runtime.host.RuntimeAnnouncementClient;
import com.resonolabs.runtime.host.RuntimeArtifactClient;
import com.resonolabs.runtime.host.T3Client;
import com.resonolabs.ui.power.AlwaysOnVoice;
import com.resonolabs.ui.power.SideButtonSetting;
import com.resonolabs.feature.compose.ComposeSheet;
import com.resonolabs.feature.compose.DictationSession;
import com.resonolabs.feature.genui.GenBlock;
import com.resonolabs.feature.genui.GenCardStore;
import com.resonolabs.feature.voicenote.VoiceNoteController;
import com.resonolabs.feature.voicenote.VoiceNoteMachine;
import com.resonolabs.feature.voicenote.VoiceNoteOverlay;

final class ProductRootView extends FrameLayout {
    private static final String ANNOUNCE_TAG = "SamAnnounce";
    private final VoicePageView voice;
    private final SettingsPanelView settings;
    private final CardsPageView cards;
    private final ProductChromeView chrome;
    private final R1MotorServiceClient motor;
    private final CameraHandoffPage camera;
    private final BackgroundRunPanelView runner;
    private final CreationImportView creationImport;
    private final ControlCenterView controlCenter;
    private final T3PageView t3;
    private boolean t3Open;
    /** The T3 tab was opened from a Cards board widget: BACK out of it returns to the board. */
    private boolean t3ReturnsToCards;
    private boolean settingsOpen;
    private boolean cardsOpen;
    private boolean cameraOpen;
    private boolean cameraHandoffOpen;
    private boolean cardContentOpen;
    private boolean runnerOpen;
    private boolean creationImportOpen;
    private float gestureDownX;
    private float gestureDownY;
    private boolean horizontalGesture;
    private boolean pullGesture;
    /** Swipe right from the left edge = Back (Android's own gestures and nav bar are switched off). */
    private boolean edgeBackGesture;
    /** The Voice page has a card expanded to full height (chrome hidden). */
    private boolean voiceImmersive;
    private int t3NeedsYou;
    /** Runtime announcement long-poll (T3 thread updates); owned here, closed with the root. */
    private final RuntimeAnnouncementClient announcements;
    /** Direct T3 calls for app-built card buttons (Approve / Deny). */
    private final T3Client t3Actions = new T3Client();
    /** Pictures of Mac-generated UIs ({@code GET /v1/ui/artifacts/<id>/image}). */
    private final RuntimeArtifactClient artifacts;
    /** Updates that arrived while a voice session was connecting: spoken once it is live. */
    private final ArrayList<Object[]> deferredUpdates = new ArrayList<>();
    private final Runnable flushDeferred = this::flushDeferredToVoice;
    /** Side-button voice note: records over whatever page is open, sends, shows the outcome. */
    private final VoiceNoteController voiceNote;
    private final VoiceNoteOverlay noteOverlay;
    /** A note asked for while a voice session held the microphone: started once it has let go. */
    private String pendingNoteTrigger;
    private int pendingNoteTries;
    private final Runnable startPendingNote = this::startPendingNote;
    /** Voice-note outcomes waiting for a moment they can be seen (acknowledged only once shown). */
    private final LateChipQueue lateChips = new LateChipQueue();
    private final Runnable showLateChip = this::showLateChip;
    /** Tells MainActivity's IdleScreenPolicy that something that keeps the screen on started or ended. */
    private Runnable busyListener = () -> { };
    /** A finished timer rings this long: the screen stays on meanwhile. */
    private static final long TIMER_RING_MS = 2L * 60L * 1000L;
    private final GenCardStore.Listener timerWatch = new GenCardStore.Listener() {
        @Override public void onCardsChanged() { busyChanged(); }

        @Override public void onCardEvent(int event, GenCard card) { busyChanged(); }
    };

    ProductRootView(
            Activity activity,
            Runnable restart,
            ManagementPairingSource managementPairing,
            ManagementOpenAiSource openAiSource,
            RuntimeBackgroundRunClient backgroundRuns,
            RuntimeCreationImportClient creationImports
    ) {
        super(activity);
        motor = new R1MotorServiceClient(activity);
        voice = new VoicePageView(activity, this::openCameraHandoff, this::setVoiceImmersive,
                this::openPageFromCard);
        voice.setSessionListener(new VoicePageView.SessionListener() {
            @Override public void onSessionActive(boolean active) {
                // Microphone foreground service: keeps listening with the screen off.
                if (active) VoiceSessionService.hold(getContext(), "voice");
                else {
                    VoiceSessionService.release(getContext(), "voice");
                    flushDeferredAsNotifications();
                }
                busyChanged();
            }

            @Override public void onSessionLive() {
                removeCallbacks(flushDeferred);
                if (!deferredUpdates.isEmpty()) postDelayed(flushDeferred, 600L);
            }
        });
        voice.setHostActions(this::onCardHostAction);
        // Text fields dictate through their own mic; never while a voice session holds it.
        ComposeSheet.setVoiceSessionProbe(voice::isInSession);
        camera = new CameraHandoffPage(activity, motor, voice, this::returnFromCamera);
        camera.setVisibility(GONE);
        cards = new CardsPageView(activity, this::openVoiceFromCards, this::showCreation);
        cards.setVisibility(GONE);
        t3 = new T3PageView(activity, new T3PageView.Host() {
            @Override public void talkToThread(String threadId, String title) {
                ProductRootView.this.talkToThread(threadId, title);
            }

            @Override public void talkToNewThread(String projectId, String projectTitle) {
                ProductRootView.this.talkToNewThread(projectId, projectTitle);
            }

            @Override public void openSettings() {
                ProductRootView.this.openSettings();
            }

            @Override public void showChrome(boolean visible) {
                if (t3Open && !settingsOpen && !runnerOpen && !cameraOpen) {
                    chrome.setVisibility(visible ? VISIBLE : GONE);
                }
            }

            @Override public void needsYou(int count) {
                t3NeedsYou = count;
                chrome.showT3Badge(count);
            }

            @Override public void counts(int needsYou, int working) {
                voice.setT3Glance(needsYou, working);
            }
        });
        t3.setVisibility(GONE);
        chrome = new ProductChromeView(activity, this::openSettings, this::openVoice,
                this::openCards, this::openT3, this::openRunner);
        cards.setLinks(new CardsPageView.Links() {
            @Override public void openT3() { openT3FromCards(null); }
            @Override public void openT3Thread(String threadId) { openT3FromCards(threadId); }
            @Override public void openSettings() { ProductRootView.this.openSettings(); }
            @Override public void say(String text) { sayFromCard(text); }
            @Override public void openPage(String page) {
                if ("runs".equals(page)) openRunner();
                else if ("transcript".equals(page)) openVoiceFromCards();
            }
        });
        runner = new BackgroundRunPanelView(activity, backgroundRuns, chrome::showRuns,
                this::closeRunner);
        runner.setVisibility(GONE);
        creationImport = new CreationImportView(activity, motor, creationImports, this::closeCreationImport);
        creationImport.setVisibility(GONE);
        settings = new SettingsPanelView(activity, this::closeSettings, restart,
                this::openCreationImport, managementPairing, openAiSource);
        settings.setVisibility(GONE);
        addView(voice, match());
        addView(cards, match());
        addView(t3, match());
        addView(camera, match());
        addView(runner, match());
        addView(creationImport, match());
        LayoutParams chromeParams = new LayoutParams(LayoutParams.MATCH_PARENT, (int) ProductChromeView.HEIGHT);
        addView(chrome, chromeParams);
        addView(settings, match());
        controlCenter = new ControlCenterView(activity, this::openSettingsFromControls, this::controlCenterClosed);
        addView(controlCenter, match());
        voiceNote = new VoiceNoteController(activity, voice::isInSession, new VoiceNoteController.Listener() {
            @Override public void onVoiceNoteChanged() {
                noteOverlay.update();
                if (!voiceNote.showing()) showLateChip(); // a result just closed: a waiting chip may show
            }

            @Override public void onVoiceNoteLater(String captureId, String line, boolean ok) {
                queueLateChip(captureId, line, ok, 0L);
            }

            @Override public void onVoiceNoteActive(boolean active) {
                // The microphone service keeps the last words coming if a single press sleeps the screen.
                if (active) {
                    VoiceSessionService.hold(getContext(), "note");
                    noteOverlay.bringToFront();
                } else {
                    VoiceSessionService.release(getContext(), "note");
                }
                busyChanged();
            }
        });
        noteOverlay = new VoiceNoteOverlay(activity, voiceNote);
        addView(noteOverlay, match());
        GenCardStore.get(activity).addListener(timerWatch);
        refreshSideButtonHint();
        setFocusable(true);
        setFocusableInTouchMode(true);
        setContentDescription("SamRabbit HOME");
        runner.start();
        t3.stop(); // Hidden: only the slow badge poll runs until the T3 tab opens.
        artifacts = new RuntimeArtifactClient(activity);
        announcements = new RuntimeAnnouncementClient(activity, this::onAnnouncement);
    }

    private LayoutParams match() {
        return new LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT);
    }

    private void openSettings() {
        settingsOpen = true;
        voice.setVisibility(GONE);
        cards.setVisibility(GONE);
        cards.stop();
        hideT3();
        chrome.setVisibility(GONE);
        settings.setVisibility(VISIBLE);
        settings.requestFocus();
    }

    private void openRunner() {
        runnerOpen = true;
        voice.setVisibility(GONE); cards.setVisibility(GONE); hideT3(); chrome.setVisibility(GONE);
        runner.setVisibility(VISIBLE); runner.opened(); runner.requestFocus();
    }

    private void closeRunner() {
        runnerOpen = false; runner.setVisibility(GONE); chrome.setVisibility(cardPageShown() ? GONE : VISIBLE);
        restoreTab();
    }

    private void closeSettings() {
        settingsOpen = false;
        settings.setVisibility(GONE);
        chrome.setVisibility(cardPageShown() ? GONE : VISIBLE);
        restoreTab();
    }

    /** A Cards page (Calendar, Tasks, Live, a creation) is up: it draws its own back button where the tabs sit. */
    private boolean cardPageShown() {
        return cardsOpen && cardContentOpen;
    }

    private void openCreationImport() {
        creationImportOpen = true;
        busyChanged();
        settings.setVisibility(GONE);
        creationImport.setVisibility(VISIBLE);
        creationImport.start();
        creationImport.requestFocus();
    }

    private void closeCreationImport() {
        creationImportOpen = false;
        busyChanged();
        creationImport.stop();
        creationImport.setVisibility(GONE);
        settings.setVisibility(VISIBLE);
        settings.requestFocus();
    }

    private void openT3() {
        t3ReturnsToCards = false;
        if (t3Open) return;
        if (cardsOpen) {
            cardsOpen = false;
            cards.stop();
            cards.setVisibility(GONE);
        }
        t3Open = true;
        chrome.showTab(ProductChromeView.TAB_T3);
        chrome.showT3Done(false);
        voice.setVisibility(GONE);
        showT3();
    }

    private void closeT3() {
        t3ReturnsToCards = false;
        if (!t3Open) return;
        t3Open = false;
        t3.stop();
        t3.setVisibility(GONE);
        chrome.setVisibility(VISIBLE);
    }

    /** A board widget opened the T3 tab, optionally straight into one thread. */
    private void openT3FromCards(String threadId) {
        openT3();
        t3ReturnsToCards = true;
        if (threadId != null && !threadId.isBlank()) t3.openThread(threadId);
    }

    /** BACK on the T3 tab: its own screens first, then the board if a widget opened it, else Voice. */
    private void backFromT3() {
        boolean wasDetail = t3.detailOpen();
        boolean handled = t3.onInput(UiInputIntent.BACK);
        boolean leftThread = wasDetail && !t3.detailOpen();
        if (!handled || (t3ReturnsToCards && leftThread)) {
            if (t3ReturnsToCards) openCards();
            else openVoice();
        }
    }

    /** A card's "say" button on the Cards tab: continue in Voice with that request. */
    private void sayFromCard(String text) {
        openVoiceFromCards();
        voice.startSessionWithNote("Host note (from a card on the R1's Cards tab): the user tapped a card button "
                + "asking \u201c" + text.trim() + "\u201d. Treat it as their request and answer it.");
    }

    /** Shows the selected T3 tab; the chrome stays hidden while a thread is open. */
    private void showT3() {
        t3.setVisibility(VISIBLE);
        t3.start();
        t3.requestFocus();
        chrome.setVisibility(t3.detailOpen() ? GONE : VISIBLE);
    }

    /** Hide (but keep selected) the T3 tab while an overlay page owns the screen. */
    private void hideT3() {
        if (!t3Open) return;
        t3.stop();
        t3.setVisibility(GONE);
    }

    /** Re-show whichever top-level tab was selected before an overlay page opened. */
    private void restoreTab() {
        if (cardsOpen) {
            cards.setVisibility(VISIBLE);
            cards.start();
            cards.requestFocus();
        } else if (t3Open) {
            showT3();
        } else {
            voice.setVisibility(VISIBLE);
            voice.requestFocus();
            if (voiceImmersive) chrome.setVisibility(GONE);
        }
    }

    /**
     * T3 "Talk": switch to Voice and tell the model that what the user says next is for this
     * thread (sent with t3_send_message unless they say otherwise).
     */
    void talkToThread(String threadId, String title) {
        String name = title == null || title.isBlank() ? "Untitled thread" : title.trim();
        openVoice();
        voice.startSessionWithNote("Host note (from the R1's T3 tab, not the user's words): the user is looking at "
                + "T3 Code thread \u201c" + name + "\u201d (id " + threadId + ") and tapped Talk. Treat what "
                + "they say next as a message for that thread and send it with t3_send_message, passing thread=\""
                + threadId + "\", unless they clearly ask for something else; use t3_respond with the same thread "
                + "for its pending approvals or questions. Confirm in a few words once it is sent. Right now, "
                + "briefly ask what they want to tell that thread, then wait.");
    }

    /** T3 "Talk" on the new-thread screen: what the user says next becomes the first prompt. */
    void talkToNewThread(String projectId, String projectTitle) {
        // t3_new_thread takes the project by name ("project"), not by id.
        boolean known = projectId != null && !projectId.isBlank()
                && projectTitle != null && !projectTitle.isBlank();
        String where = known
                ? "project \u201c" + projectTitle.trim() + "\u201d"
                : "their most recently active project";
        String how = known
                ? "create it with t3_new_thread, passing the prompt and project=\"" + projectTitle.trim()
                        + "\" unless they name another project"
                : "create it with t3_new_thread, passing the prompt and no project unless they name one";
        openVoice();
        voice.startSessionWithNote("Host note (from the R1's T3 tab, not the user's words): the user wants to start "
                + "a new T3 Code thread in " + where + ". Treat what they say next as the prompt and " + how
                + ", then confirm in one short sentence. Right now, briefly ask what the new thread should do, "
                + "then wait.");
    }

    private void openCards() {
        closeT3();
        cardsOpen = true;
        chrome.showTab(ProductChromeView.TAB_CARDS);
        // A swipe can leave Voice while a GenUI card is expanded (chrome hidden there).
        chrome.setVisibility(cardContentOpen ? GONE : VISIBLE);
        voice.setVisibility(GONE);
        cards.setVisibility(VISIBLE);
        cards.start();
        cards.requestFocus();
    }

    /**
     * Voice from inside the Cards tab (BACK on the board, a Calendar or Tasks page's Voice button,
     * a card's say or transcript action). An open card page is closed first: it hides the tab bar
     * and blocks tab swipes, so leaving it open behind Voice stranded the user on Voice without
     * tabs. Unwinds like the side button does.
     */
    private void openVoiceFromCards() {
        for (int depth = 0; depth < 4 && cardContentOpen; depth++) cards.onInput(UiInputIntent.BACK);
        openVoice();
    }

    private void openVoice() {
        closeT3();
        cardsOpen = false;
        chrome.showTab(ProductChromeView.TAB_VOICE);
        cards.stop();
        cards.setVisibility(GONE);
        voice.setVisibility(VISIBLE);
        voice.requestFocus();
        chrome.setVisibility(voiceImmersive ? GONE : VISIBLE);
    }

    /** GenUI: a card expanded to full height hides the chrome (posted by the Voice page). */
    private void setVoiceImmersive(boolean value) {
        voiceImmersive = value;
        boolean voiceShowing = !cardsOpen && !t3Open && !settingsOpen && !runnerOpen && !cameraOpen
                && !creationImportOpen;
        if (voiceShowing) chrome.setVisibility(value ? GONE : VISIBLE);
    }

    /** A card button or glance chip asked for a page (GenSchema.OPEN_PAGES, t3, t3:<id>). */
    private void openPageFromCard(String page) {
        if (page == null) return;
        String thread = T3AnnouncementCards.threadFromOpenTarget(page);
        if (thread != null) {
            openT3ThreadById(thread);
            return;
        }
        switch (page) {
            case "cards", "calendar", "tasks" -> openCards();
            case "briefing" -> {
                openCards();
                cards.openBriefing(null);
            }
            case "runs" -> openRunner();
            case "t3" -> openT3();
            default -> { }
        }
    }

    /** Opens one T3 thread in the T3 tab from anywhere (card Open, notification tap). */
    void openT3ThreadById(String threadId) {
        if (threadId == null || threadId.isBlank()) return;
        if (controlCenter.isOpen()) controlCenter.hide();
        if (creationImportOpen) closeCreationImport();
        if (runnerOpen) closeRunner();
        if (cameraOpen) { camera.stop(); returnFromCamera(); }
        if (settingsOpen) closeSettings();
        if (cardsOpen) {
            for (int depth = 0; depth < 4 && cardContentOpen; depth++) cards.onInput(UiInputIntent.BACK);
        }
        openT3();
        t3.openThread(threadId);
        chrome.setVisibility(t3.detailOpen() ? GONE : VISIBLE);
        T3UpdateNotifier.cancel(getContext(), threadId);
    }

    // ---- announcements (T3 thread updates) -------------------------------------------------

    private void onAnnouncement(JSONObject item) {
        String kind = text(item, "kind");
        AnnouncementRouting.Route route = AnnouncementRouting.route(kind, voice.isLive(), voice.isStarting());
        Log.i(ANNOUNCE_TAG, "announcement " + item.optLong("id", 0L) + " " + kind + " -> " + route);
        switch (route) {
            case VOICE -> deliverToVoice(item);
            case DEFER -> deferredUpdates.add(new Object[]{item, android.os.SystemClock.uptimeMillis()});
            case NOTIFY -> deliverAsNotification(item);
            case SILENT -> deliverSilently(item);
            case IGNORE -> { }
        }
    }

    /**
     * A voice note's outcome that arrived after the note closed (it waited for the Mac): a chip at
     * the top for a few seconds, acknowledged "seen" once it was really on screen (not under a note,
     * not with the screen off). {@code briefing.ready}: nothing to show here (the Cards board reads
     * the brief itself), acknowledged at once. Never spoken.
     */
    private void deliverSilently(JSONObject item) {
        String kind = text(item, "kind");
        JSONObject payload = item.optJSONObject("payload");
        String chip = AnnouncementRouting.captureChip(kind, text(payload, "say"), text(item, "text"));
        long id = item.optLong("id", 0L);
        if (chip.isEmpty()) {
            announcements.ack(id, AnnouncementRouting.CHANNEL_SEEN);
            return;
        }
        queueLateChip(text(payload, "captureId"), chip, AnnouncementRouting.captureOk(kind, text(payload, "state")), id);
    }

    private void queueLateChip(String captureId, String line, boolean ok, long announcementId) {
        for (long id : lateChips.add(new LateChipQueue.Chip(captureId, line, ok, announcementId))) {
            announcements.ack(id, AnnouncementRouting.CHANNEL_SEEN);
        }
        showLateChip();
    }

    /**
     * Shows the next waiting voice-note outcome once it can be seen: the screen on, no note on screen,
     * no other chip up. Tried again when a note closes, a chip ends and the screen comes on.
     */
    void showLateChip() {
        removeCallbacks(showLateChip);
        if (lateChips.isEmpty()) return;
        if (noteOverlay.chipShowing()) {
            postDelayed(showLateChip, VoiceNoteOverlay.chipMs() + 300L);
            return;
        }
        if (voiceNote.showing() || !screenOn()) return;
        LateChipQueue.Chip chip = lateChips.next();
        noteOverlay.showChip(chip.text, chip.ok);
        if (chip.announcementId > 0) announcements.ack(chip.announcementId, AnnouncementRouting.CHANNEL_SEEN);
        if (!lateChips.isEmpty()) postDelayed(showLateChip, VoiceNoteOverlay.chipMs() + 300L);
    }

    private boolean screenOn() {
        PowerManager power = getContext().getSystemService(PowerManager.class);
        return power == null || power.isInteractive();
    }

    private void deliverToVoice(JSONObject item) {
        JSONObject payload = item.optJSONObject("payload");
        String kind = text(item, "kind");
        if (AnnouncementRouting.isUi(kind)) {
            deliverUi(item);
            return;
        }
        String envelope = AnnouncementRouting.voiceEnvelope(kind, text(item, "text"), text(payload, "lastMessage"));
        if (!voice.deliverHostUpdate(envelope, item.optLong("id", 0L), kind)) {
            deliverAsNotification(item);
            return;
        }
        showT3Card(item);
        announcements.ack(item.optLong("id", 0L), AnnouncementRouting.CHANNEL_VOICE);
    }

    private void deliverAsNotification(JSONObject item) {
        JSONObject payload = item.optJSONObject("payload");
        String kind = text(item, "kind");
        if (AnnouncementRouting.isUi(kind)) {
            // Presented once its picture is here: to the model if a session went live meanwhile.
            deliverUi(item);
            return;
        }
        String threadId = T3AnnouncementCards.threadId(item);
        String title = text(payload, "title");
        if (title.isEmpty()) title = text(item, "title");
        if (title.isEmpty()) title = "T3 Code";
        T3UpdateNotifier.post(getContext(), threadId, title,
                AnnouncementRouting.notificationText(text(item, "text"), text(payload, "lastMessage")));
        if (AnnouncementRouting.needsYou(kind)) chrome.showT3Badge(Math.max(1, t3NeedsYou));
        else if (!t3Open) chrome.showT3Done(true);
        showT3Card(item); // a pill on the idle Voice page
        announcements.ack(item.optLong("id", 0L), AnnouncementRouting.CHANNEL_NOTIFICATION);
    }

    // ---- announcements: Mac-generated UIs (ui.generated / ui.failed, CONTRACTS-WAVE3 §5-6) ----

    /** Fetches a generated UI's picture (404 and failures still present it, without one). */
    private void deliverUi(JSONObject item) {
        String kind = text(item, "kind");
        if (AnnouncementRouting.UI_FAILED.equals(kind)) {
            presentUiFailure(item);
            return;
        }
        String artifactId = text(item.optJSONObject("payload"), "artifactId");
        // Synthetic (debug) announcements have id 0: never a notification sound for those.
        boolean silent = item.optLong("id", 0L) <= 0L;
        if (!RuntimeArtifactClient.validId(artifactId)) {
            presentGeneratedUi(item, null, null, silent);
            return;
        }
        artifacts.fetchImage(artifactId, new RuntimeArtifactClient.Callback() {
            @Override public void onImage(byte[] bytes, String mime) {
                presentGeneratedUi(item, bytes, mime, silent);
            }

            @Override public void onFailure(String reason) {
                Log.i(ANNOUNCE_TAG, "generated UI picture unavailable (" + reason + ")");
                presentGeneratedUi(item, null, null, silent);
            }
        });
    }

    /**
     * Transcript item + host card always; the live model sees it (picture + caption), otherwise
     * a notification and a "New: …" pill on the idle Voice page.
     */
    private void presentGeneratedUi(JSONObject item, byte[] image, String mime, boolean silent) {
        JSONObject payload = item.optJSONObject("payload");
        String artifactId = text(payload, "artifactId");
        String title = text(payload, "title");
        if (title.isEmpty()) title = text(item, "title");
        String summary = text(payload, "summary");
        if (summary.isEmpty()) summary = text(item, "text");
        long id = item.optLong("id", 0L);
        if (voice.showGeneratedUi(artifactId, title, summary, image, mime)) {
            announcements.ack(id, AnnouncementRouting.CHANNEL_VOICE);
            return;
        }
        GeneratedUiNotifier.post(getContext(), artifactId,
                AnnouncementRouting.uiNotificationTitle(AnnouncementRouting.UI_GENERATED, title),
                AnnouncementRouting.uiNotificationText(AnnouncementRouting.UI_GENERATED, summary, ""), silent);
        announcements.ack(id, AnnouncementRouting.CHANNEL_NOTIFICATION);
    }

    private void presentUiFailure(JSONObject item) {
        JSONObject payload = item.optJSONObject("payload");
        String artifactId = text(payload, "artifactId");
        // Only the payload names the UI: the announcement's own title is the runtime's headline
        // ("Visual not made"), not the artifact's name.
        String title = text(payload, "title");
        Object rawError = payload == null ? null : payload.opt("error");
        String error = AnnouncementRouting.uiFailureReason(text(payload, "message"),
                rawError instanceof JSONObject object ? text(object, "message") : "",
                rawError instanceof String string ? string : "");
        long id = item.optLong("id", 0L);
        String kind = AnnouncementRouting.UI_FAILED;
        if (voice.deliverHostUpdate(AnnouncementRouting.uiFailedEnvelope(title, error), id, kind)) {
            announcements.ack(id, AnnouncementRouting.CHANNEL_VOICE);
            return;
        }
        GeneratedUiNotifier.post(getContext(), artifactId, AnnouncementRouting.uiNotificationTitle(kind, title),
                AnnouncementRouting.uiNotificationText(kind, "", error), id <= 0L);
        announcements.ack(id, AnnouncementRouting.CHANNEL_NOTIFICATION);
    }

    /** A tapped "Generated UIs" notification: Voice, with that picture full screen if it is here. */
    void openGeneratedUi(String artifactId) {
        showVoicePage();
        voice.openGeneratedUi(artifactId);
        GeneratedUiNotifier.cancel(getContext(), artifactId);
    }

    /** Shows or refreshes the live card following this thread (never two cards per thread). */
    private void showT3Card(JSONObject item) {
        String threadId = T3AnnouncementCards.threadId(item);
        if (threadId == null) return;
        GenCard existing = voice.genUi().findLiveCard(LiveBinding.Type.T3_THREAD, threadId);
        JSONObject card = T3AnnouncementCards.cardJson(item, existing == null ? null : existing.id);
        if (card != null) voice.genUi().showHostCard(card);
    }

    private void flushDeferredToVoice() {
        long now = android.os.SystemClock.uptimeMillis();
        ArrayList<Object[]> pending = new ArrayList<>(deferredUpdates);
        deferredUpdates.clear();
        for (Object[] entry : pending) {
            JSONObject item = (JSONObject) entry[0];
            boolean fresh = now - (Long) entry[1] <= AnnouncementRouting.DEFER_MAX_MS;
            if (fresh && voice.isLive()) deliverToVoice(item);
            else deliverAsNotification(item);
        }
    }

    private void flushDeferredAsNotifications() {
        removeCallbacks(flushDeferred);
        ArrayList<Object[]> pending = new ArrayList<>(deferredUpdates);
        deferredUpdates.clear();
        for (Object[] entry : pending) deliverAsNotification((JSONObject) entry[0]);
    }

    /** Approve / Deny on a T3 announcement card: answered directly with the exact requestId. */
    private void onCardHostAction(GenCard card, String action) {
        T3AnnouncementCards.Approval approval = T3AnnouncementCards.parseApproval(action);
        if (approval == null) return;
        String title = card.displayTitle();
        String cardId = card.id;
        t3Actions.respondApproval(getContext(), approval.threadId, approval.requestId, approval.decision,
                new T3Client.Callback() {
                    @Override public void onResult(JSONObject value) {
                        Log.i(ANNOUNCE_TAG, "card " + approval.decision + " sent for " + approval.threadId);
                        JSONObject next = T3AnnouncementCards.afterDecision(cardId, approval.threadId, title,
                                approval.accept());
                        if (next != null) voice.genUi().showHostCard(next);
                        voice.sendUiEvent("[UI event] The user tapped " + (approval.accept() ? "Approve" : "Deny")
                                + " on the card for the T3 thread \u201c" + title + "\u201d; the request was "
                                + (approval.accept() ? "approved" : "declined") + ". Do not ask about it again.");
                    }

                    @Override public void onFailure(T3Client.Failure failure) {
                        Log.w(ANNOUNCE_TAG, "card " + approval.decision + " failed: " + failure);
                        Toast.makeText(getContext(), failure.httpStatus == 409
                                ? "That request was already answered" : "Couldn't reach T3 Code",
                                Toast.LENGTH_SHORT).show();
                    }
                });
    }

    private static String text(JSONObject json, String key) {
        if (json == null || json.isNull(key)) return "";
        Object value = json.opt(key);
        return value instanceof String string ? string.trim() : "";
    }

    // ---- debug hooks (VoiceDebugReceiver, debug builds only) -------------------------------

    /**
     * DEBUG_SAY: show Voice and send {@code text} as the user's turn (starting a session).
     * {@code quiet} mutes the microphone and the speaker for this session first, so a test
     * makes no sound and cannot hear itself.
     */
    void debugSay(String text, boolean quiet) {
        showVoicePage();
        voice.debugSay(text, quiet);
    }

    /** DEBUG_ANNOUNCE: route a synthetic announcement exactly like a runtime one. */
    void debugAnnounce(JSONObject item) {
        onAnnouncement(item);
    }

    /**
     * DEBUG_PICTURE: a fake picture item without the runtime ({@code source} camera,
     * mac_screenshot or generated_ui). A generated UI goes through the real announcement path
     * (live → model, idle → notification + pill) with {@code image} instead of the fetch; its
     * synthetic announcement id 0 is never acknowledged.
     */
    void debugPicture(String source, byte[] image, String title, String summary, String artifactId) {
        showVoicePage();
        if ("generated_ui".equals(source)) {
            try {
                JSONObject item = new JSONObject().put("id", 0).put("kind", AnnouncementRouting.UI_GENERATED)
                        .put("title", title).put("text", summary)
                        .put("payload", new JSONObject().put("artifactId", artifactId).put("title", title)
                                .put("summary", summary));
                presentGeneratedUi(item, image, "image/jpeg", true);
            } catch (Exception invalid) {
                Log.w(ANNOUNCE_TAG, "debug picture failed");
            }
            return;
        }
        voice.debugAddPicture(source, image, title, summary, artifactId);
    }

    /** DEBUG_PICTURE --ez clear true: test pictures, their cards and "Generated UIs" notifications go. */
    int debugClearPictures() {
        int removed = voice.debugClearPictures();
        android.app.NotificationManager notifications =
                getContext().getSystemService(android.app.NotificationManager.class);
        if (notifications != null) {
            for (android.service.notification.StatusBarNotification posted : notifications.getActiveNotifications()) {
                if ("ui".equals(posted.getTag())) notifications.cancel(posted.getTag(), posted.getId());
            }
        }
        return removed;
    }

    /** DEBUG_TRANSCRIPT: open/close the Voice transcript, optionally the newest picture full screen. */
    void debugTranscript(boolean open, boolean viewer) {
        showVoicePage();
        voice.debugTranscript(open, viewer);
    }

    /**
     * DEBUG_NOTE: the voice-note overlay in a given state without the microphone or the runtime
     * (screenshots): {@code phase} LISTENING | FINISHING | SENT | QUEUED | NOTHING_HEARD | FAILED, or
     * {@code chip} for the late-outcome chip; {@code close} hides it.
     */
    void debugVoiceNote(String phase, String words, String line) {
        if ("chip".equalsIgnoreCase(phase)) {
            noteOverlay.showChip(line == null || line.isBlank() ? "Added to your journal" : line, true);
            return;
        }
        if ("close".equalsIgnoreCase(phase)) {
            voiceNote.debugPreview(null, "", "");
            return;
        }
        VoiceNoteMachine.Phase value;
        try {
            value = VoiceNoteMachine.Phase.valueOf(phase == null ? "" : phase.trim().toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException unknown) {
            value = VoiceNoteMachine.Phase.LISTENING;
        }
        voiceNote.debugPreview(value, words == null ? "" : words, line == null ? "" : line);
        noteOverlay.bringToFront();
    }

    /** One-line state for debug broadcasts. */
    String debugState() {
        return "inSession=" + voice.isInSession() + " live=" + voice.isLive() + " starting=" + voice.isStarting()
                + " alwaysOn=" + AlwaysOnVoice.isEnabled(getContext()) + " note=" + voiceNote.machine().phase()
                + " busy=" + screenBusy() + " page=" + debugPage();
    }

    /** What is in front, so test scripts never tap into a page someone else has open. */
    private String debugPage() {
        if (controlCenter.isOpen()) return "control-center";
        if (creationImportOpen) return "creation-import";
        if (runnerOpen) return "runner";
        if (cameraOpen) return "camera";
        if (settingsOpen) {
            String sub = settings.openPageName();
            return sub == null ? "settings" : "settings:" + sub.replace(' ', '-');
        }
        if (cardsOpen) return "cards";
        if (t3Open) return t3.detailOpen() ? "t3-thread" : "t3";
        return voice.viewerOpen() ? "voice:viewer" : "voice";
    }

    private void showCreation(boolean visible) {
        cardContentOpen = visible;
        chrome.setVisibility(visible ? GONE : VISIBLE);
    }

    private void openCameraHandoff() {
        cameraOpen = true;
        cameraHandoffOpen = true;
        voice.setVisibility(GONE); cards.setVisibility(GONE); hideT3(); chrome.setVisibility(GONE);
        camera.setVisibility(VISIBLE); camera.startHandoff(); camera.requestFocus();
        busyChanged();
    }

    private void openCamera() {
        if (settingsOpen || cameraOpen) return;
        cameraOpen = true;
        voice.setVisibility(GONE); cards.setVisibility(GONE); hideT3(); chrome.setVisibility(GONE);
        camera.setVisibility(VISIBLE); camera.startPreview(); camera.requestFocus();
        busyChanged();
    }

    private void returnFromCamera() {
        cameraOpen = false;
        cameraHandoffOpen = false;
        camera.setVisibility(GONE); chrome.setVisibility(cardContentOpen ? GONE : VISIBLE);
        restoreTab();
        busyChanged();
    }

    @Override public boolean onInterceptTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            gestureDownX = event.getX();
            gestureDownY = event.getY();
            horizontalGesture = false;
            pullGesture = false;
            edgeBackGesture = false;
        }
        if (action == MotionEvent.ACTION_MOVE && gestureDownX <= 24f * getWidth() / 480f) {
            float dx = event.getX() - gestureDownX;
            float dy = event.getY() - gestureDownY;
            if (dx >= 36f * getWidth() / 480f && dx > Math.abs(dy) * 1.2f) {
                edgeBackGesture = true;
                return true;
            }
        }
        // The voice note owns the screen: taps send it; only the edge swipe (Back = cancel) passes.
        if (voiceNote.showing()) return false;
        if (controlCenter.isOpen() || settingsOpen || runnerOpen || creationImportOpen) return false;
        switch (action) {
            case MotionEvent.ACTION_MOVE -> {
                float dx = event.getX() - gestureDownX;
                float dy = event.getY() - gestureDownY;
                float scale = getHeight() / 640f;
                if (!cameraOpen && gestureDownY <= 130f * scale && dy >= 48f * scale
                        && dy > Math.abs(dx) * 1.4f) {
                    pullGesture = true;
                    return true;
                }
                if (Math.abs(dx) >= 42f && Math.abs(dx) > Math.abs(dy) * 1.4f) {
                    horizontalGesture = true;
                    return true;
                }
            }
            default -> { }
        }
        return false;
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (edgeBackGesture) {
            int action = event.getActionMasked();
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                edgeBackGesture = false;
                if (action == MotionEvent.ACTION_UP
                        && event.getX() - gestureDownX >= 72f * getWidth() / 480f) navigateBack();
            }
            return true;
        }
        if (pullGesture) {
            if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                pullGesture = false;
                openControlCenter();
            } else if (event.getActionMasked() == MotionEvent.ACTION_UP
                    || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
                pullGesture = false;
            }
            return true;
        }
        if (!horizontalGesture) return true;
        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            float dx = event.getX() - gestureDownX;
            if (cameraOpen) {
                if (dx >= 72f) {
                    camera.stop();
                    returnFromCamera();
                }
            } else if (dx <= -72f) {
                cycleTab(1);
            } else if (dx >= 72f) {
                cycleTab(-1);
            }
            horizontalGesture = false;
        } else if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            horizontalGesture = false;
        }
        return true;
    }

    /** Horizontal swipes page through the tabs and wrap around: Voice → Cards → T3 → Voice. */
    private void cycleTab(int step) {
        if (cardsOpen && cardContentOpen) return;   // a card page (Calendar, a creation) keeps the swipe
        int current = t3Open ? 2 : cardsOpen ? 1 : 0;
        switch (Math.floorMod(current + step, 3)) {
            case 1 -> openCards();
            case 2 -> openT3();
            default -> openVoice();
        }
    }

    boolean onHardwareKey(KeyEvent event) {
        UiInputIntent intent = HardwareInputRouter.keyIntent(event.getKeyCode());
        if (intent == null) return false;
        if (event.getAction() == KeyEvent.ACTION_DOWN) dispatch(intent);
        return true;
    }

    boolean onHardwareMotion(MotionEvent event) {
        UiInputIntent intent = HardwareInputRouter.motionIntent(event);
        if (intent == null) return false;
        dispatch(intent);
        return true;
    }

    void openControlCenter() {
        if (controlCenter.isOpen() || cameraOpen || creationImportOpen) return;
        controlCenter.bringToFront();
        controlCenter.show();
    }

    private void openSettingsFromControls() {
        if (runnerOpen) closeRunner();
        if (!settingsOpen) openSettings();
    }

    private void controlCenterClosed() {
        if (settingsOpen) settings.requestFocus();
        else if (runnerOpen) runner.requestFocus();
        else if (cardsOpen) cards.requestFocus();
        else if (t3Open) t3.requestFocus();
        else voice.requestFocus();
    }

    boolean navigateBack() {
        if (voiceNote.showing()) {
            // BACK cancels a recording (nothing is sent), lets a sending note go on off screen, or closes a result.
            if (!voiceNote.cancel() && !voiceNote.sendInBackground()) voiceNote.dismissResult();
            return true;
        }
        if (controlCenter.isOpen()) return controlCenter.onInput(UiInputIntent.BACK);
        if (creationImportOpen) return creationImport.onInput(UiInputIntent.BACK);
        if (runnerOpen) return runner.onInput(UiInputIntent.BACK);
        if (cameraOpen) {
            camera.stop();
            returnFromCamera();
            return true;
        }
        if (settingsOpen) return settings.onInput(UiInputIntent.BACK);
        if (cardsOpen) return cards.onInput(UiInputIntent.BACK);
        if (t3Open) {
            backFromT3();
            return true;
        }
        // Voice is the visible page: BACK closes its transcript, then ends a live session.
        return voice.onInput(UiInputIntent.BACK);
    }

    /**
     * Side-button double press (see SideButtonGesture). A live session is stopped from wherever
     * the user is, even mid-reply; otherwise every panel/overlay is closed, Voice is shown and a
     * session starts. Returns true when a session was started.
     */
    boolean toggleVoiceFromSideButton() {
        if (voiceNote.recording()) {
            // Any side-button gesture finishes a recording note (and the mic stays with the note).
            voiceNote.finish();
            return false;
        }
        // Finishing or sending: the note goes on off screen (its outcome comes as a chip) and the
        // double press talks. A finishing dictation hands the microphone to the session (DictationSession).
        if (voiceNote.active()) voiceNote.sendInBackground();
        if (voice.isInSession()) {
            stopVoiceSession();
            return false;
        }
        showVoicePage();
        voice.toggleSession();
        return true;
    }

    /** Cold start through the alias: the gesture can only mean "start". */
    boolean startVoiceFromSideButton() {
        return !voice.isInSession() && toggleVoiceFromSideButton();
    }

    /**
     * The screen went off (single side-button press). While asleep the HOME process drops to
     * TOP_SLEEPING without microphone capability, so a live session would keep running deaf.
     * Returns true when a session was ended.
     */
    boolean stopVoiceForScreenOff() {
        if (voiceNote.recording()) {
            // A single press while recording = "done, send it" (the microphone service holds on meanwhile).
            voiceNote.finish();
            Log.i(SideButtonGesture.LOG_TAG, "screen off -> voice note sent");
            return true;
        }
        if (!voice.isInSession()) return false;
        if (AlwaysOnVoice.isEnabled(getContext())) {
            // Always-on voice: the microphone foreground service keeps the session listening.
            Log.i(SideButtonGesture.LOG_TAG, "screen off -> always-on, session kept");
            return false;
        }
        stopVoiceSession();
        return true;
    }

    // ---- voice note (side button triple press / hold) ---------------------------------------

    /**
     * Triple press or hold: starts a voice note at once, or finishes and sends the one recording.
     * A live voice session is ended first (it holds the microphone). True when a note started.
     */
    boolean voiceNoteFromSideButton(String trigger) {
        if (voiceNote.recording()) {
            voiceNote.finish();
            return false;
        }
        if (voiceNote.active()) return false; // already sending
        if (ComposeSheet.anyOpen() || DictationSession.anyActive()) {
            // A text sheet is a window of its own above HOME: the note would record hidden behind it,
            // BACK would close the sheet instead of cancelling, and its dictation would share the mic.
            Log.i(SideButtonGesture.LOG_TAG, trigger + " -> no voice note (a text sheet is open)");
            Toast.makeText(getContext(), "Close the text box to record a voice note.", Toast.LENGTH_SHORT).show();
            return false;
        }
        if (controlCenter.isOpen()) controlCenter.hide();
        if (voice.isInSession()) {
            stopVoiceSession();
            pendingNoteTrigger = trigger;
            pendingNoteTries = 0;
            removeCallbacks(startPendingNote);
            postDelayed(startPendingNote, 350L);
            return true;
        }
        return voiceNote.start(trigger);
    }

    private void startPendingNote() {
        if (pendingNoteTrigger == null) return;
        if (voice.isInSession() && ++pendingNoteTries < 6) {
            postDelayed(startPendingNote, 300L);
            return;
        }
        String trigger = pendingNoteTrigger;
        pendingNoteTrigger = null;
        voiceNote.start(trigger);
    }

    /** Recording now: any side-button gesture finishes and sends it (later phases let a double press talk). */
    boolean voiceNoteRecording() {
        return voiceNote.recording();
    }

    /** Stop listening and send (a double press, a tap, the wheel). */
    boolean finishVoiceNote() {
        return voiceNote.finish();
    }

    /**
     * The note's input while it is on screen: press/tap sends, BACK cancels, the wheel is ignored.
     * While it sends, either gives the screen back (it still goes); on a result, either closes it.
     */
    private void onVoiceNoteInput(UiInputIntent intent) {
        if (intent == UiInputIntent.ACTIVATE) {
            if (voiceNote.recording()) voiceNote.finish();
            else if (!voiceNote.sendInBackground()) voiceNote.dismissResult();
        } else if (intent == UiInputIntent.BACK) {
            if (!voiceNote.cancel() && !voiceNote.sendInBackground()) voiceNote.dismissResult();
        }
    }

    /** The idle Voice page hint names the voice-note gesture chosen in Settings > Side button. */
    void refreshSideButtonHint() {
        SideButtonSetting.VoiceNote choice = SideButtonSetting.voiceNote(getContext());
        voice.setIdleHint(switch (choice) {
            case HOLD -> "Double-press to talk · hold for a note";
            case BOTH -> "Double-press to talk · triple-press or hold for a note";
            default -> "Double-press to talk · triple-press for a note";
        });
    }

    // ---- screen idle (MainActivity's IdleScreenPolicy) ---------------------------------------

    void setBusyListener(Runnable listener) {
        busyListener = listener == null ? () -> { } : listener;
    }

    private void busyChanged() {
        busyListener.run();
    }

    /**
     * True while the screen must stay on: a voice session (or one connecting), a voice note or any
     * dictation, an open text sheet, a running or ringing timer, the camera or a QR import.
     */
    boolean screenBusy() {
        return voice.isInSession() || voice.isStarting() || voiceNote.active() || DictationSession.anyActive()
                || ComposeSheet.anyOpen() || cameraOpen || creationImportOpen || timerKeepsScreenOn();
    }

    private boolean timerKeepsScreenOn() {
        GenCardStore store = GenCardStore.get(getContext());
        long now = store.now();
        for (GenCard card : store.activeCards()) {
            if (!card.isTimer()) continue;
            GenBlock timer = card.timerBlock();
            if (timer == null) continue;
            if (!timer.done && !timer.paused) return true;
            if (timer.done && now - timer.endsAt < TIMER_RING_MS) return true;
        }
        return false;
    }

    private void stopVoiceSession() {
        // The camera hand-off belongs to the session being ended; leave it with the session.
        if (cameraOpen && cameraHandoffOpen) { camera.stop(); returnFromCamera(); }
        voice.toggleSession();
    }

    private void showVoicePage() {
        if (controlCenter.isOpen()) controlCenter.hide();
        if (creationImportOpen) closeCreationImport();
        if (runnerOpen) closeRunner();
        if (cameraOpen) { camera.stop(); returnFromCamera(); }
        if (settingsOpen) closeSettings();
        if (cardsOpen) {
            // Unwind calendar/tasks/creation first so the chrome comes back together with Voice.
            for (int depth = 0; depth < 4 && cardContentOpen; depth++) cards.onInput(UiInputIntent.BACK);
            if (cardsOpen) openVoice();
        }
        if (t3Open) openVoice();
    }

    private void dispatch(UiInputIntent intent) {
        if (voiceNote.showing()) onVoiceNoteInput(intent);
        else if (controlCenter.isOpen()) controlCenter.onInput(intent);
        else if (creationImportOpen) creationImport.onInput(intent);
        else if (runnerOpen) runner.onInput(intent);
        else if (settingsOpen) settings.onInput(intent);
        else if (cardsOpen) cards.onInput(intent);
        else if (t3Open) {
            if (intent == UiInputIntent.BACK) backFromT3();
            else t3.onInput(intent);
        }
        else voice.onInput(intent);
    }

    void close() {
        removeCallbacks(flushDeferred);
        removeCallbacks(startPendingNote);
        removeCallbacks(showLateChip);
        GenCardStore.get(getContext()).removeListener(timerWatch);
        voiceNote.close();
        // Voice first: ending its session turns deferred T3 updates into notifications and
        // acks them; the announcement client then closes and still sends those queued acks
        // (an unacked item would be replayed when HOME starts again).
        voice.close();
        announcements.close();
        artifacts.close();
        t3Actions.close();
        cards.close();
        t3.close();
        camera.close();
        creationImport.close();
        runner.stop();
        motor.close();
    }
}
