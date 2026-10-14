package com.resonolabs.feature.voicenote;

/**
 * What the app does when the runtime did not answer a voice note (pure; unit-tested). The runtime
 * stores a note before it tries the Mac, so a request that reached it and then timed out is safe
 * there; a refused connection (the runtime restarting) is tried again twice, then the note is kept
 * in the app and resent with the same capture id until the runtime takes it. Only a refusal of the
 * note itself (bad words or time: a 4xx) is a failure.
 */
final class NoteDelivery {
    enum Next { RETRY, KEEP, FAILED }

    /** Quick retries for a runtime that is just starting (then the note waits in the app). */
    static final long[] RETRY_MS = {1_500L, 4_000L};
    /** How often notes kept in the app are offered to the runtime again. */
    static final long RESEND_MS = 15_000L;
    static final String TIMEOUT = "runtime_timeout";

    private NoteDelivery() {}

    /** {@code httpStatus} 0: no answer ({@code code} runtime_timeout = it was delivered). */
    static Next after(int httpStatus, String code, int attempts) {
        if (httpStatus == 0) {
            if (TIMEOUT.equals(code)) return Next.KEEP;
            return attempts < RETRY_MS.length ? Next.RETRY : Next.KEEP;
        }
        if (httpStatus >= 500 || httpStatus == 401 || httpStatus == 403 || httpStatus == 408 || httpStatus == 429) {
            return Next.KEEP;
        }
        return Next.FAILED;
    }

    static long retryDelayMs(int attempts) {
        return RETRY_MS[Math.max(0, Math.min(attempts, RETRY_MS.length - 1))];
    }

    /** A resent note's answer worth a chip: the Mac acted or refused it ("queued"/"sent" say nothing new). */
    static boolean worthAChip(String state) {
        return "done".equals(state) || "failed".equals(state);
    }
}
