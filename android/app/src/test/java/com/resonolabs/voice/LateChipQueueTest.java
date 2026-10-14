package com.resonolabs.voice;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.util.List;

import org.junit.Test;

public final class LateChipQueueTest {
    @Test public void chipsWaitInOrderAndAreAckedOnlyWhenTaken() {
        LateChipQueue queue = new LateChipQueue();
        assertTrue(queue.add(new LateChipQueue.Chip("a", "Added to your journal", true, 11L)).isEmpty());
        assertTrue(queue.add(new LateChipQueue.Chip("b", "Couldn't save that note.", false, 12L)).isEmpty());
        assertEquals(2, queue.size());
        assertEquals("a", queue.next().captureId);
        LateChipQueue.Chip failed = queue.next();
        assertEquals(12L, failed.announcementId);
        assertNull(queue.next());
    }

    @Test public void oneChipPerNote() {
        LateChipQueue queue = new LateChipQueue();
        queue.add(new LateChipQueue.Chip("a", "Added to your journal", true, 0L));
        assertEquals("the runtime's announcement of the same note is acked without a second chip",
                List.of(21L), queue.add(new LateChipQueue.Chip("a", "Added to your journal", true, 21L)));
        assertEquals(1, queue.size());
        queue.next();
        assertEquals("already shown", List.of(22L), queue.add(new LateChipQueue.Chip("a", "Added", true, 22L)));
        assertEquals("nothing to show", List.of(23L), queue.add(new LateChipQueue.Chip("c", " ", true, 23L)));
    }

    @Test public void failuresAreNeverPushedOut() {
        LateChipQueue queue = new LateChipQueue();
        for (int i = 0; i < LateChipQueue.MAX_WAITING; i++) {
            queue.add(new LateChipQueue.Chip("f" + i, "Couldn't save that note.", false, 100L + i));
        }
        assertTrue(queue.add(new LateChipQueue.Chip("f-extra", "Couldn't save that note.", false, 200L)).isEmpty());
        assertEquals(LateChipQueue.MAX_WAITING + 1, queue.size());
        assertEquals("good news goes first when it is full",
                List.of(300L), queue.add(new LateChipQueue.Chip("ok", "Saved", true, 300L)));
        for (int i = 0; i <= LateChipQueue.MAX_WAITING; i++) assertTrue(!queue.next().ok);
    }
}
