package com.resonolabs.voice;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

/**
 * Foreground service (microphone | mediaPlayback) held while a voice session is active, so the
 * HOME process keeps microphone capability when a single side-button press turns the screen
 * off (asleep, HOME drops to TOP_SLEEPING with no microphone otherwise). Started with a plain
 * {@code startService} while the user is interacting (HOME is the top app) and promoted in
 * {@link #onCreate}; stays up across always-on reconnects and stops when the session ends.
 * A voice note holds it the same way ({@link #hold} / {@link #release} per holder), so a single
 * press that turns the screen off while a note records still gets the last words in.
 */
public final class VoiceSessionService extends Service {
    static final String LOG_TAG = "SamVoiceService";
    private static final String CHANNEL = "sam_voice_session";
    private static final int NOTIFICATION_ID = 4102;
    /** Safety net only; the service releases the lock when the session ends. */
    private static final long WAKE_LOCK_MAX_MS = 8L * 60L * 60L * 1000L;
    private PowerManager.WakeLock wakeLock;
    /** Who needs the microphone service: "voice" (a session), "note" (a voice note). Main thread. */
    private static final java.util.Set<String> HOLDERS = new java.util.HashSet<>();

    /** {@code holder} needs the service; it starts with the first holder. */
    static void hold(Context context, String holder) {
        boolean first = HOLDERS.isEmpty();
        HOLDERS.add(holder);
        if (first) start(context);
    }

    /** {@code holder} is done; the service stops with the last one. */
    static void release(Context context, String holder) {
        if (!HOLDERS.remove(holder) || !HOLDERS.isEmpty()) return;
        stop(context);
    }

    private static void start(Context context) {
        try {
            context.startService(new Intent(context, VoiceSessionService.class));
        } catch (RuntimeException error) {
            // Background start not allowed (HOME not in front): the session still runs while
            // the screen is on; only screen-off listening is lost.
            Log.w(LOG_TAG, "voice service not started: " + error.getClass().getSimpleName());
        }
    }

    private static void stop(Context context) {
        context.stopService(new Intent(context, VoiceSessionService.class));
    }

    @Override public void onCreate() {
        super.onCreate();
        try {
            startForeground(NOTIFICATION_ID, notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                            | ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            Log.i(LOG_TAG, "voice foreground service started");
        } catch (RuntimeException error) {
            Log.w(LOG_TAG, "voice foreground service refused: " + error.getClass().getSimpleName()
                    + ": " + error.getMessage());
            stopSelf();
            return;
        }
        PowerManager power = getSystemService(PowerManager.class);
        if (power != null) {
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SamRabbit:voice");
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire(WAKE_LOCK_MAX_MS);
        }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        return START_NOT_STICKY;
    }

    @Override public void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
        stopForeground(STOP_FOREGROUND_REMOVE);
        Log.i(LOG_TAG, "voice foreground service stopped");
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) {
        return null;
    }

    private Notification notification() {
        NotificationManager notifications = getSystemService(NotificationManager.class);
        NotificationChannel channel = new NotificationChannel(CHANNEL, "Voice session",
                NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Shown while SamRabbit Voice is listening, including with the screen off.");
        channel.setSound(null, null);
        channel.enableVibration(false);
        notifications.createNotificationChannel(channel);
        PendingIntent open = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("SamRabbit is listening")
                .setContentText("Voice stays on while the screen is off")
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build();
    }
}
