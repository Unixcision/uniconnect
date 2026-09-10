package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The queued-cleanup case. Tearing a recogniser down is posted, so it runs later than it was
 * decided; if a dictation started again in between, a cleanup that emptied "the current one" would
 * destroy the engine that is now listening and leave a bar with no microphone behind it.
 */
class RecogniserSlotTest {
    /** Two engines that are equal by value and different by identity, which is the whole point. */
    private data class Engine(val name: String)

    @Test
    fun aCleanupQueuedByAnOldTryLeavesTheNewEngineAlone() {
        val slot = RecogniserSlot<Engine>()
        val first = Engine("attempt A")
        slot.replace(first)
        // A queued its cleanup here, and B took over before it ran.
        val second = Engine("attempt B")
        slot.replace(second)
        assertFalse("the cleanup of A finds B in the slot and does not touch it", slot.releaseIfHeld(first))
        assertSame("B is still the one listening", second, slot.engine)
    }

    @Test
    fun aCleanupOfTheEngineThatIsStillThereEmptiesTheSlot() {
        val slot = RecogniserSlot<Engine>()
        val engine = Engine("attempt A")
        slot.replace(engine)
        assertTrue(slot.releaseIfHeld(engine))
        assertNull(slot.engine)
        assertFalse("and doing it twice changes nothing", slot.releaseIfHeld(engine))
    }

    @Test
    fun theSlotTellsWhatItReplacedSoTheCallerCanTearItDown() {
        val slot = RecogniserSlot<Engine>()
        val first = Engine("attempt A")
        assertNull("nothing was there before the first one", slot.replace(first))
        val second = Engine("attempt B")
        assertSame(first, slot.replace(second))
        assertSame(second, slot.clear())
        assertNull(slot.clear())
    }

    @Test
    fun twoEnginesThatLookAlikeAreStillTwoEngines() {
        val slot = RecogniserSlot<Engine>()
        val held = Engine("igual")
        val other = Engine("igual")
        slot.replace(held)
        assertFalse("equal by value is not the same engine", slot.releaseIfHeld(other))
        assertSame(held, slot.engine)
    }
}
