package com.resonolabs.voice;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.nio.charset.StandardCharsets;

/**
 * Debug-only voice test hooks (src/debug; never in release builds). {@code -p} is required.
 *
 * <pre>
 * adb shell 'am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_SAY --es text "What is on my calendar tomorrow?" --ez quiet true'
 * adb shell am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_SAY --es b64 $(printf '%s' "$TEXT" | base64) --ez quiet true
 * adb shell am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_ANNOUNCE --es b64 $(printf '%s' "$JSON" | base64)
 * adb shell am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_STATE
 * adb shell 'am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_PICTURE --es source generated_ui --es title "Weekly focus hours" --es summary "Bar chart of focus hours per day"'
 * adb shell 'am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_TRANSCRIPT --ez open true --ez viewer false'
 * adb shell 'am broadcast -p com.resonolabs.voice.engineering -a com.resonolabs.voice.DEBUG_NOTE --es phase SENT --es line "Added to your journal"'
 * </pre>
 * DEBUG_NOTE shows the voice-note overlay in one state with no microphone, no dictation and nothing
 * sent (screenshots): {@code phase} LISTENING | FINISHING | SENDING | SENT | QUEUED | NOTHING_HEARD |
 * FAILED, {@code chip} (the late-outcome chip) or {@code close}; {@code words} the live words,
 * {@code line} the result line.
 * DEBUG_PICTURE adds a synthetic picture (no runtime, no camera, no Mac): {@code source} camera,
 * mac_screenshot or generated_ui (default). A generated UI takes the real announcement path
 * (live session: shown to the model; idle: a silent notification and a "New: …" pill).
 * DEBUG_TRANSCRIPT opens/closes the Voice transcript; {@code --ez viewer true} opens the newest
 * picture full screen. {@code DEBUG_PICTURE --ez clear true} removes every picture from the
 * transcript, every picture card (stack, deck, Recent) and the "Generated UIs" notifications.
 * Quote the whole remote command (or use {@code --es b64}): {@code adb shell} re-splits its
 * arguments on the device, so an unquoted multi-word {@code --es text "..."} arrives as its first
 * word only and the flags after it ({@code --ez quiet true}) are silently dropped, which starts
 * an audible session with a live microphone.
 * DEBUG_SAY sends the text as the user's turn in the live session (conversation.item.create
 * user input_text + response.create), starting a session first if none is live (the text then
 * replaces the connect greeting). Sessions it starts are QUIET by default (microphone and speaker
 * muted, no sound, no echo); pass {@code --ez quiet false} only when sound is really needed. DEBUG_ANNOUNCE routes a synthetic runtime announcement exactly
 * like a real one (ids &lt;= 0 are never acknowledged). The result data is the HOME state.
 */
public final class VoiceDebugReceiver extends BroadcastReceiver {
    private static final String TAG = "SamVoiceDebug";

    @Override public void onReceive(Context context, Intent intent) {
        String action = intent.getAction() == null ? "" : intent.getAction();
        ProductRootView root = MainActivity.activeRoot();
        if (root == null) {
            setResultData("no-home");
            return;
        }
        if (action.endsWith("DEBUG_SAY")) {
            String text = extra(intent, "text");
            if (text == null || text.isBlank()) {
                setResultData("missing --es text");
                return;
            }
            // Quiet unless a caller explicitly asks for sound (--ez quiet false): the user sits next to the R1.
            boolean quiet = intent.getBooleanExtra("quiet", true);
            Log.i(TAG, "DEBUG_SAY (" + text.length() + " chars" + (quiet ? ", quiet" : "") + ")");
            root.debugSay(text, quiet);
        } else if (action.endsWith("DEBUG_PICTURE") && intent.getBooleanExtra("clear", false)) {
            int removed = root.debugClearPictures();
            Log.i(TAG, "DEBUG_PICTURE clear (" + removed + " card(s))");
        } else if (action.endsWith("DEBUG_PICTURE")) {
            String source = extra(intent, "source");
            if (source == null || source.isBlank()) source = "generated_ui";
            String title = intent.getStringExtra("title");
            String summary = intent.getStringExtra("summary");
            String id = intent.getStringExtra("id");
            if (id == null || id.isBlank()) id = "dbg" + Long.toHexString(System.currentTimeMillis());
            if ("generated_ui".equals(source)) {
                if (title == null || title.isBlank()) title = "Weekly focus hours";
                if (summary == null) summary = "Bar chart of focus hours per day; Thursday peaks at 7.4 h.";
            } else if (summary == null) {
                summary = "camera".equals(source) ? "You sent this photo" : "Screenshot";
            }
            byte[] image = DebugPictures.forSource(source, title);
            Log.i(TAG, "DEBUG_PICTURE " + source + " (" + image.length + " bytes)");
            root.debugPicture(source, image, title, summary, id);
        } else if (action.endsWith("DEBUG_TRANSCRIPT")) {
            root.debugTranscript(intent.getBooleanExtra("open", true), intent.getBooleanExtra("viewer", false));
        } else if (action.endsWith("DEBUG_NOTE")) {
            root.debugVoiceNote(extra(intent, "phase"), intent.getStringExtra("words"), intent.getStringExtra("line"));
        } else if (action.endsWith("DEBUG_ANNOUNCE")) {
            String json = extra(intent, "json");
            try {
                root.debugAnnounce(new JSONObject(json == null ? "{}" : json));
            } catch (Exception invalid) {
                setResultData("invalid json");
                return;
            }
        }
        setResultData(root.debugState());
    }

    /** {@code --es <name>} or base64 in {@code --es b64} (for text with quotes or spaces). */
    private static String extra(Intent intent, String name) {
        String value = intent.getStringExtra(name);
        if (value != null) return value;
        String encoded = intent.getStringExtra("b64");
        if (encoded == null) return null;
        try {
            return new String(Base64.decode(encoded, Base64.DEFAULT), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException invalid) {
            return null;
        }
    }
}
