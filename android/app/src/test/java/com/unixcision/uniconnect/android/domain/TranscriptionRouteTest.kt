package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which engine dictates, for every combination of the setting and what the machine announces. */
class TranscriptionRouteTest {
    @Test
    fun automaticPrefersTheMachineThatAnnouncesTheCapability() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, hostTranscribes = true)
        assertEquals(TranscriptionEngine.HOST, route.engine)
        assertNull("nothing to say when the machine does what is expected", route.notice)
    }

    @Test
    fun automaticFallsBackToThePhoneAndSaysSoOnce() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, hostTranscribes = false)
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertEquals(TranscriptionNotice.HOST_CANNOT, route.notice)
        assertFalse("a fact about the machine is said once", route.notice!!.repeats)
    }

    @Test
    fun alwaysOnThePhoneNeverAsksTheMachineNorExplainsItself() {
        listOf(true, false).forEach { announces ->
            val route = TranscriptionRoute.decide(TranscriptionMode.PHONE, hostTranscribes = announces)
            assertEquals(TranscriptionEngine.PHONE, route.engine)
            assertNull(route.notice)
        }
    }

    @Test
    fun alwaysOnTheMachineWarnsEveryTimeTheMachineCannot() {
        val able = TranscriptionRoute.decide(TranscriptionMode.HOST, hostTranscribes = true)
        assertEquals(TranscriptionEngine.HOST, able.engine)
        assertNull(able.notice)
        val unable = TranscriptionRoute.decide(TranscriptionMode.HOST, hostTranscribes = false)
        assertEquals("what the reader asked for is impossible, so the phone dictates", TranscriptionEngine.PHONE, unable.engine)
        assertEquals(TranscriptionNotice.HOST_REQUIRED_UNAVAILABLE, unable.notice)
        assertTrue("an unmet explicit choice is said every time", unable.notice!!.repeats)
    }

    @Test
    fun aPhoneWithoutARecogniserStillDictatesThroughAMachineThatCan() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, hostTranscribes = true, phoneAvailable = false)
        assertEquals(TranscriptionEngine.HOST, route.engine)
        assertTrue(TranscriptionRoute.canDictate(TranscriptionMode.AUTO, hostTranscribes = true, phoneAvailable = false))
        assertTrue(TranscriptionRoute.canDictate(TranscriptionMode.HOST, hostTranscribes = true, phoneAvailable = false))
        assertFalse("nothing can dictate", TranscriptionRoute.canDictate(TranscriptionMode.AUTO, hostTranscribes = false, phoneAvailable = false))
        assertFalse("the phone was demanded and there is none", TranscriptionRoute.canDictate(TranscriptionMode.PHONE, hostTranscribes = true, phoneAvailable = false))
    }

    @Test
    fun aPhoneWithoutARecogniserIsNotToldAboutAnAutomaticFallback() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, hostTranscribes = false, phoneAvailable = false)
        assertNull("there is no microphone to explain anything about", route.notice)
    }

    @Test
    fun aStoredModeSurvivesAndAnythingUnknownIsAutomatic() {
        assertEquals(TranscriptionMode.HOST, TranscriptionMode.named("HOST"))
        assertEquals(TranscriptionMode.PHONE, TranscriptionMode.named("PHONE"))
        assertEquals(TranscriptionMode.AUTO, TranscriptionMode.named(null))
        assertEquals(TranscriptionMode.AUTO, TranscriptionMode.named("WHISPER"))
    }
}
