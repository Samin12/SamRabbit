package com.resonolabs.ui.power;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class IdleScreenClockTest {
    private static final long TEN_MIN = IdleScreenClock.DEFAULT_IDLE_MS;

    @Test public void staysOnForTenMinutesAfterTheLastInteraction() {
        IdleScreenClock clock = new IdleScreenClock(1_000L);
        IdleScreenClock.Decision early = clock.decide(1_000L + TEN_MIN - 1L, TEN_MIN);
        assertTrue(early.keep);
        assertEquals(1_000L + TEN_MIN, early.nextCheckAt);
        clock.interaction(300_000L);
        assertTrue("a touch moves the deadline", clock.decide(1_000L + TEN_MIN, TEN_MIN).keep);
        IdleScreenClock.Decision late = clock.decide(300_000L + TEN_MIN, TEN_MIN);
        assertFalse(late.keep);
        assertEquals(Long.MAX_VALUE, late.nextCheckAt);
    }

    @Test public void busyKeepsItOnAndTheIdleTimeStartsWhenBusyEnds() {
        IdleScreenClock clock = new IdleScreenClock(0L);
        clock.busy(true, 5_000L);
        IdleScreenClock.Decision busy = clock.decide(2 * TEN_MIN, TEN_MIN);
        assertTrue("a voice session or a running timer keeps the screen on", busy.keep);
        assertEquals(2 * TEN_MIN + IdleScreenClock.BUSY_CHECK_MS, busy.nextCheckAt);
        clock.busy(false, 2 * TEN_MIN);
        assertTrue("ten more minutes after the session ended", clock.decide(3 * TEN_MIN - 1L, TEN_MIN).keep);
        assertFalse(clock.decide(3 * TEN_MIN, TEN_MIN).keep);
    }

    @Test public void neverKeepsTheScreenOn() {
        IdleScreenClock.Decision decision = IdleScreenClock.decide(Long.MAX_VALUE / 2, 0L, false, Long.MIN_VALUE,
                IdleScreenClock.NEVER);
        assertTrue(decision.keep);
        assertEquals(Long.MAX_VALUE, decision.nextCheckAt);
    }

    @Test public void anOlderInteractionNeverMovesTheClockBack() {
        IdleScreenClock clock = new IdleScreenClock(50_000L);
        clock.interaction(10_000L);
        assertEquals(50_000L, clock.lastInteractionAt());
    }
}
