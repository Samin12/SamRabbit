package com.resonolabs.feature.compose;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import com.resonolabs.feature.compose.DictationMachine.Action;
import com.resonolabs.feature.compose.DictationMachine.Phase;
import com.resonolabs.feature.compose.DictationMachine.Stop;

import org.junit.Test;

public class DictationMachineTest {
    private static DictationMachine live(long at) {
        DictationMachine machine = new DictationMachine();
        assertTrue(machine.start(at));
        machine.onLive(at + 500L);
        return machine;
    }

    @Test public void happyPathListensFinishesAndCloses() {
        DictationMachine machine = new DictationMachine();
        assertEquals(Phase.IDLE, machine.phase());
        assertTrue(machine.start(0L));
        assertFalse("one dictation at a time", machine.start(10L));
        assertEquals(Phase.CONNECTING, machine.phase());
        machine.onLive(800L);
        assertEquals(Phase.LISTENING, machine.phase());
        machine.onSpeechStarted(1_000L);
        assertEquals(Action.NONE, machine.tick(2_000L, 1));
        machine.onSpeechStopped(3_000L);
        assertEquals(Action.MUTE, machine.stop(3_100L, Stop.USER));
        assertEquals(Phase.FINISHING, machine.phase());
        assertEquals("waits for the last words", Action.NONE, machine.tick(3_300L, 1));
        assertEquals(Action.CLOSE, machine.tick(3_500L, 0));
        assertEquals(Phase.DONE, machine.phase());
        assertEquals(Stop.USER, machine.stopReason());
        assertFalse(machine.active());
        machine.reset();
        assertEquals(Phase.IDLE, machine.phase());
        assertTrue(machine.start(5_000L));
    }

    @Test public void stopsAtTheMaxDuration() {
        DictationMachine machine = live(0L);
        machine.onSpeechStarted(600L);
        assertEquals(Action.NONE, machine.tick(500L + DictationMachine.MAX_LISTEN_MS - 1L, 1));
        assertEquals(Action.MUTE, machine.tick(500L + DictationMachine.MAX_LISTEN_MS, 1));
        assertEquals(Stop.MAX_DURATION, machine.stopReason());
    }

    @Test public void remainingCountsDownWhileListening() {
        DictationMachine machine = live(0L);
        assertEquals(DictationMachine.MAX_LISTEN_MS - 1_500L, machine.remainingMs(2_000L));
    }

    @Test public void stopsAfterTrailingSilence() {
        DictationMachine machine = live(0L);
        machine.onSpeechStarted(1_000L);
        machine.onSpeechStopped(4_000L);
        assertEquals(Action.NONE, machine.tick(4_000L + DictationMachine.TRAILING_SILENCE_MS - 1L, 0));
        machine.onSpeechStarted(5_000L);
        assertEquals("talking again resets the silence", Action.NONE,
                machine.tick(4_000L + DictationMachine.TRAILING_SILENCE_MS + 10L, 1));
        machine.onSpeechStopped(9_000L);
        assertEquals(Action.MUTE, machine.tick(9_000L + DictationMachine.TRAILING_SILENCE_MS, 0));
        assertEquals(Stop.SILENCE, machine.stopReason());
    }

    @Test public void stopsWhenNothingIsSaid() {
        DictationMachine machine = live(0L);
        assertEquals(Action.NONE, machine.tick(500L + DictationMachine.NO_SPEECH_MS - 1L, 0));
        assertEquals(Action.MUTE, machine.tick(500L + DictationMachine.NO_SPEECH_MS, 0));
        assertEquals(Stop.NO_SPEECH, machine.stopReason());
        assertEquals(Action.CLOSE, machine.tick(500L + DictationMachine.NO_SPEECH_MS + 200L, 0));
    }

    @Test public void stopWhileStillTalkingWaitsForVadThenCommits() {
        DictationMachine machine = live(0L);
        machine.onSpeechStarted(1_000L);
        assertEquals(Action.MUTE, machine.stop(2_000L, Stop.USER));
        assertEquals(Action.NONE, machine.tick(2_200L, 1));
        assertEquals(Action.COMMIT, machine.tick(2_000L + DictationMachine.COMMIT_AFTER_MS, 1));
        assertEquals("commits once", Action.NONE, machine.tick(2_000L + DictationMachine.COMMIT_AFTER_MS + 200L, 1));
        machine.onCommitted(3_800L);
        assertFalse(machine.speechActive());
        assertEquals(Action.CLOSE, machine.tick(3_900L, 0));
    }

    @Test public void finishingGivesUpAfterTheTimeout() {
        DictationMachine machine = live(0L);
        machine.onSpeechStarted(1_000L);
        machine.onSpeechStopped(1_500L);
        assertEquals(Action.MUTE, machine.stop(2_000L, Stop.USER));
        assertEquals(Action.NONE, machine.tick(2_000L + DictationMachine.FINISH_TIMEOUT_MS - 1L, 2));
        assertEquals(Action.CLOSE, machine.tick(2_000L + DictationMachine.FINISH_TIMEOUT_MS, 2));
    }

    @Test public void stopWhileConnectingClosesAtOnce() {
        DictationMachine machine = new DictationMachine();
        machine.start(0L);
        assertEquals(Action.CLOSE, machine.stop(100L, Stop.VOICE_SESSION));
        assertEquals(Stop.VOICE_SESSION, machine.stopReason());
        machine.onLive(200L);
        assertEquals("a late live after stop is ignored", Phase.DONE, machine.phase());
    }

    @Test public void connectTimeoutFails() {
        DictationMachine machine = new DictationMachine();
        machine.start(0L);
        assertEquals(Action.NONE, machine.tick(DictationMachine.CONNECT_TIMEOUT_MS - 1L, 0));
        assertEquals(Action.CLOSE, machine.tick(DictationMachine.CONNECT_TIMEOUT_MS, 0));
        assertEquals(Stop.FAILED, machine.stopReason());
    }

    @Test public void cancelAndFailCloseFromAnyActivePhase() {
        DictationMachine machine = live(0L);
        assertEquals(Action.CLOSE, machine.cancel());
        assertEquals(Stop.CANCELLED, machine.stopReason());
        assertEquals("cancel is idempotent", Action.NONE, machine.cancel());

        DictationMachine failing = live(0L);
        failing.stop(1_000L, Stop.USER);
        assertEquals(Action.CLOSE, failing.fail());
        assertEquals(Stop.FAILED, failing.stopReason());
        assertEquals(Action.NONE, failing.stop(1_200L, Stop.USER));
    }

    @Test public void vadEventsOutsideADictationAreIgnored() {
        DictationMachine machine = new DictationMachine();
        machine.onSpeechStarted(10L);
        assertFalse(machine.speechActive());
        assertEquals(Action.NONE, machine.tick(100_000L, 0));
    }

    @Test public void voiceNoteLimitsListenLongerAndStopSoonerAfterTheWords() {
        DictationMachine.Limits note = new DictationMachine.Limits(180_000L, 8_000L, 2_500L, 15_000L);
        DictationMachine machine = new DictationMachine(note);
        assertTrue(machine.start(0L));
        machine.onLive(500L);
        machine.onSpeechStarted(1_000L);
        assertEquals("past the sheet's 60 s cap", Action.NONE, machine.tick(500L + 61_000L, 1));
        machine.onSpeechStopped(70_000L);
        assertEquals(Action.NONE, machine.tick(70_000L + 2_499L, 0));
        assertEquals(Action.MUTE, machine.tick(70_000L + 2_500L, 0));
        assertEquals(Stop.SILENCE, machine.stopReason());
        assertEquals(180_000L, new DictationMachine(note).remainingMs(0L));
        assertEquals(DictationMachine.MAX_LISTEN_MS, new DictationMachine().remainingMs(0L));
        assertTrue(DictationMachine.Limits.DEFAULT == new DictationMachine().limits());
    }
}
