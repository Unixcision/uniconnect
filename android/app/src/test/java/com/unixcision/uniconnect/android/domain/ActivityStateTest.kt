package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** The host's words map to states, and a workspace shows the most pressing of its windows. */
class ActivityStateTest {
    @Test
    fun hostWordsMapToStatesAndAnythingElseIsUnknown() {
        assertEquals(ActivityState.WORKING, ActivityState.parse("working"))
        assertEquals(ActivityState.WAITING, ActivityState.parse("waiting"))
        assertEquals(ActivityState.IDLE, ActivityState.parse("idle"))
        assertEquals(ActivityState.UNKNOWN, ActivityState.parse("busy"))
        assertEquals(ActivityState.UNKNOWN, ActivityState.parse(null))
    }

    @Test
    fun aQuestionOutranksWorkWhichOutranksRest() {
        assertEquals(ActivityState.WAITING, ActivityState.summarize(listOf(ActivityState.WORKING, ActivityState.WAITING, ActivityState.IDLE)))
        assertEquals(ActivityState.WORKING, ActivityState.summarize(listOf(ActivityState.IDLE, ActivityState.WORKING, ActivityState.UNKNOWN)))
        assertEquals(ActivityState.IDLE, ActivityState.summarize(listOf(ActivityState.UNKNOWN, ActivityState.IDLE)))
        assertEquals(ActivityState.UNKNOWN, ActivityState.summarize(emptyList()))
    }
}
