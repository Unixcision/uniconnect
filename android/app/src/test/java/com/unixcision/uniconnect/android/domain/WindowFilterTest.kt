package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The machine screen's filter: everything, the windows working, or the ones waiting. */
class WindowFilterTest {
    @Test
    fun eachFilterAcceptsItsOwnStateAndAllAcceptsEvenTheUnknown() {
        assertTrue(WindowFilter.ALL.accepts(null))
        assertTrue(WindowFilter.ALL.accepts(ActivityState.IDLE))
        assertTrue(WindowFilter.WORKING.accepts(ActivityState.WORKING))
        assertFalse(WindowFilter.WORKING.accepts(ActivityState.WAITING))
        assertTrue(WindowFilter.WAITING.accepts(ActivityState.WAITING))
        assertFalse(WindowFilter.WAITING.accepts(null))
    }
}
