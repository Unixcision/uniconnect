package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** Sizes as the settings sheet says them, and the percentage under a download. */
class ByteSizeTest {
    @Test
    fun aSizeIsSaidInTheUnitAPhoneUses() {
        assertEquals("0 B", ByteSize.format(0))
        assertEquals("512 B", ByteSize.format(512))
        assertEquals("1 kB", ByteSize.format(1024))
        assertEquals("1,5 kB", ByteSize.format(1536))
        assertEquals("56,9 MB", ByteSize.format(SpeechModel.BASE.bytes))
        assertEquals("181 MB", ByteSize.format(SpeechModel.SMALL.bytes))
    }

    @Test
    fun aDecimalIsDroppedAsSoonAsItStopsMeaningAnything() {
        assertEquals("a hundred and something is not measured to the tenth", "812 MB", ByteSize.format(851_443_712))
        assertEquals("1,4 GB", ByteSize.format(1_503_238_553))
    }

    @Test
    fun aPercentageNeverLeavesItsRangeAndAnUnknownTotalIsZero() {
        assertEquals(0, ByteSize.percent(0, 100))
        assertEquals(50, ByteSize.percent(50, 100))
        assertEquals(99, ByteSize.percent(99_999, 100_000))
        assertEquals(100, ByteSize.percent(200, 100))
        assertEquals("nothing is known yet, so nothing is claimed", 0, ByteSize.percent(10, 0))
    }
}
