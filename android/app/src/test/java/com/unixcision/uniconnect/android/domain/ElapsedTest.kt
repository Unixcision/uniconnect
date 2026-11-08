package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** "Hace 2 min" rounds down the way a person says it, and a clock ahead of the host reads as now. */
class ElapsedTest {
    @Test
    fun roundsDownToTheLargestWholeUnit() {
        assertEquals(Elapsed.Now, Elapsed.between(1000, 1059))
        assertEquals(Elapsed.Minutes(1), Elapsed.between(1000, 1060))
        assertEquals(Elapsed.Minutes(59), Elapsed.between(0, 3599))
        assertEquals(Elapsed.Hours(1), Elapsed.between(0, 3600))
        assertEquals(Elapsed.Hours(23), Elapsed.between(0, 86_399))
        assertEquals(Elapsed.Days(2), Elapsed.between(0, 2 * 86_400 + 5))
    }

    @Test
    fun aSinceInTheFutureIsNow() {
        assertEquals(Elapsed.Now, Elapsed.between(5000, 1000))
    }
}
