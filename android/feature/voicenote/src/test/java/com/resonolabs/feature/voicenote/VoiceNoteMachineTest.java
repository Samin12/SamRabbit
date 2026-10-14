package com.resonolabs.feature.voicenote;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import com.resonolabs.feature.voicenote.VoiceNoteMachine.Phase;

import org.junit.Test;

public final class VoiceNoteMachineTest {
    private static VoiceNoteMachine listening() {
        VoiceNoteMachine machine = new VoiceNoteMachine();
        assertTrue(machine.start(0L));
        machine.onLive(400L);
        return machine;
    }

    @Test public void recordsFinishesSendsAndShowsTheOutcome() {
        VoiceNoteMachine machine = listening();
        assertEquals(Phase.LISTENING, machine.phase());
        assertTrue(machine.recording());
        assertFalse("one note at a time", machine.start(500L));
        assertTrue(machine.finish(5_400L));
        assertEquals(Phase.FINISHING, machine.phase());
        assertFalse("a second press while finishing does nothing", machine.finish(5_500L));
        assertTrue(machine.onWords("put it in the journal ship it", 6_000L));
        assertEquals(Phase.SENDING, machine.phase());
        assertEquals(5_000L, machine.durationMs(9_000L));
        assertFalse("sending can't be cancelled: it is already stored", machine.cancel(6_100L));
        machine.onSent("done", "Added to your journal", 6_500L);
        assertEquals(Phase.SENT, machine.phase());
        assertEquals("Sent ✓", machine.title());
        assertEquals("Added to your journal", machine.line());
        assertFalse(machine.active());
        assertTrue(machine.showing(6_500L + VoiceNoteMachine.RESULT_MS - 1L));
        assertFalse(machine.tick(6_500L + VoiceNoteMachine.RESULT_MS - 1L));
        assertTrue(machine.tick(6_500L + VoiceNoteMachine.RESULT_MS));
        assertEquals(Phase.IDLE, machine.phase());
        assertTrue(machine.start(20_000L));
    }

    @Test public void silenceOrTheCapEndsItWithoutATap() {
        VoiceNoteMachine machine = listening();
        assertTrue("dictation stopped on its own after the words", machine.onWords("call mom", 3_000L));
        assertEquals(Phase.SENDING, machine.phase());
    }

    @Test public void nothingHeardSendsNothing() {
        VoiceNoteMachine machine = listening();
        assertFalse(machine.onWords("  ", 8_500L));
        assertEquals(Phase.NOTHING_HEARD, machine.phase());
        assertEquals("Nothing was sent.", machine.line());
    }

    @Test public void backCancelsAndNothingIsSent() {
        VoiceNoteMachine machine = listening();
        assertTrue(machine.cancel(1_000L));
        assertEquals(Phase.CANCELLED, machine.phase());
        assertFalse("words after a cancel are dropped", machine.onWords("too late", 1_100L));
        assertEquals(Phase.CANCELLED, machine.phase());
    }

    @Test public void queuedAndFailedOutcomesStayLonger() {
        VoiceNoteMachine machine = listening();
        machine.onWords("note", 1_000L);
        machine.onSent("queued", "Saved. It goes to your Mac when it's back.", 2_000L);
        assertEquals(Phase.QUEUED, machine.phase());
        assertEquals("Saved ✓", machine.title());
        assertTrue(machine.showing(2_000L + VoiceNoteMachine.LONG_RESULT_MS - 1L));
        VoiceNoteMachine failed = listening();
        failed.onFailure("Connect OpenAI in Settings to dictate.", 900L);
        assertEquals(Phase.FAILED, failed.phase());
        assertEquals("Connect OpenAI in Settings to dictate.", failed.line());
        assertFalse(failed.active());
    }

    @Test public void countdownShowsForTheLastFifteenSeconds() {
        VoiceNoteMachine machine = listening();
        long cap = 180_000L;
        assertFalse(machine.countdown(400L + cap - VoiceNoteMachine.COUNTDOWN_MS - 1L, cap));
        assertTrue(machine.countdown(400L + cap - VoiceNoteMachine.COUNTDOWN_MS, cap));
        assertEquals(1_000L, machine.remainingMs(400L + cap - 1_000L, cap));
    }

    @Test public void aSendingNoteGivesTheScreenBackAndStillGoes() {
        VoiceNoteMachine machine = listening();
        assertFalse("recording: a gesture finishes it instead", machine.toBackground(1_000L));
        machine.onWords("make a new task fix the login", 2_000L);
        assertEquals(Phase.SENDING, machine.phase());
        assertEquals("Tap to close · it still sends", machine.hint());
        assertTrue(machine.toBackground(2_100L));
        assertEquals(Phase.IDLE, machine.phase());
        assertFalse("the overlay is gone at once", machine.showing(2_100L));
        assertFalse("no longer holding the screen or the mic service", machine.active());
        machine.onSent("done", "Started a T3 task", 3_000L);
        assertEquals("a late answer is the caller's chip, not a full-screen result", Phase.IDLE, machine.phase());
        assertTrue("the next note can start right away", machine.start(3_100L));
    }

    @Test public void aFinishingNoteOffScreenStillSendsItsLastWords() {
        VoiceNoteMachine machine = listening();
        machine.finish(1_000L);
        assertTrue(machine.toBackground(1_100L));
        assertTrue(machine.background());
        assertFalse(machine.showing(1_100L));
        assertTrue("still active until the words are in", machine.active());
        assertTrue("the words still go", machine.onWords("call the dentist", 1_600L));
        assertEquals(Phase.IDLE, machine.phase());
        assertFalse(machine.background());
        assertFalse(machine.showing(1_600L));
        VoiceNoteMachine quiet = listening();
        quiet.finish(1_000L);
        quiet.toBackground(1_100L);
        assertFalse("nothing heard: nothing to send", quiet.onWords(" ", 1_500L));
        assertEquals(Phase.IDLE, quiet.phase());
        VoiceNoteMachine broken = listening();
        broken.finish(1_000L);
        broken.toBackground(1_100L);
        broken.onFailure("Lost the connection. Try again.", 1_400L);
        assertEquals(Phase.IDLE, broken.phase());
        assertFalse(broken.showing(1_400L));
    }

    @Test public void aTapClosesAResultEarly() {
        VoiceNoteMachine machine = listening();
        machine.onWords("x", 1_000L);
        machine.onSent("sent", "", 1_200L);
        assertEquals("Sent to your Mac.", machine.line());
        machine.dismiss(1_300L);
        assertTrue(machine.tick(1_300L));
        assertFalse(machine.showing(1_300L));
    }
}
