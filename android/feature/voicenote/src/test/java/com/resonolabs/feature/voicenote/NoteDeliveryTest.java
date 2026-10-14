package com.resonolabs.feature.voicenote;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.resonolabs.feature.voicenote.NoteDelivery.Next;

import org.junit.Test;

public final class NoteDeliveryTest {
    @Test public void aTimeoutIsNotALostNote() {
        assertEquals("the runtime stores a note before it tries the Mac: saved, not 'not saved'",
                Next.KEEP, NoteDelivery.after(0, "runtime_timeout", 0));
    }

    @Test public void aRestartingRuntimeIsRetriedThenTheNoteWaitsInTheApp() {
        assertEquals(Next.RETRY, NoteDelivery.after(0, "runtime_unavailable", 0));
        assertEquals(Next.RETRY, NoteDelivery.after(0, "runtime_unavailable", 1));
        assertEquals("never thrown away", Next.KEEP, NoteDelivery.after(0, "runtime_unavailable", 2));
        assertEquals(1_500L, NoteDelivery.retryDelayMs(0));
        assertEquals(4_000L, NoteDelivery.retryDelayMs(1));
        assertEquals(4_000L, NoteDelivery.retryDelayMs(7));
        assertEquals(Next.KEEP, NoteDelivery.after(503, "", 0));
        assertEquals(Next.KEEP, NoteDelivery.after(401, "unauthorized", 0));
    }

    @Test public void onlyARefusalOfTheNoteItselfFails() {
        assertEquals(Next.FAILED, NoteDelivery.after(400, "invalid_request", 0));
        assertEquals(Next.FAILED, NoteDelivery.after(413, "", 0));
    }

    @Test public void resentNotesOnlyChipTheirOutcome() {
        assertTrue(NoteDelivery.worthAChip("done"));
        assertTrue(NoteDelivery.worthAChip("failed"));
        assertFalse("the runtime announces those itself later", NoteDelivery.worthAChip("queued"));
        assertFalse(NoteDelivery.worthAChip("sent"));
    }

    @Test public void aKeptNoteRoundTripsWithItsCaptureId() {
        PendingNote note = new PendingNote("6f1c2d3e-0000-4000-8000-000000000001", "put it in the journal ship it",
                "2026-10-14T09:41:07-04:00", 4_200L, "triple_press", 1_000L);
        PendingNote back = PendingNote.fromJson(note.toJson());
        assertEquals(note.id, back.id);
        assertEquals(note.text, back.text);
        assertEquals(note.capturedAt, back.capturedAt);
        assertEquals(4_200L, back.durationMs);
        assertEquals("triple_press", back.trigger);
        assertNull("no words, no note", PendingNote.fromJson(
                new PendingNote("x", " ", "2026-10-14T09:41:07-04:00", 0L, "", 0L).toJson()));
        assertNull(PendingNote.fromJson("not json"));
    }
}
