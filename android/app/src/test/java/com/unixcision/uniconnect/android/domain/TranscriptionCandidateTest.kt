package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone keeps a live link only to the machine of the open window, but the recording opens its
 * own connection: a machine the phone is not watching right now still transcribes. Seen with the
 * Linux box open, whose UniConnect announces `transcribe.v1` with no whisper installed: the Mac
 * was left out for not being watched and the dictation ended up on the phone, and badly.
 */
class TranscriptionCandidateTest {
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)
    private val linux = Machine("linux", "MINIPC", MachineEndpoint.parse("100.64.0.2", "58465")!!)
    private val transcribing = MachineSnapshot("equipo", emptyList(), setOf(MachineSnapshot.TRANSCRIBE))

    @Test
    fun aMachineThePhoneIsNotWatchingStillTranscribesWhileItsLastContactWorked() {
        val candidate = TranscriptionCandidate.of(mac, transcribing, watched = false, lastContactFailed = false)
        assertTrue("the recording opens its own connection to it", candidate.ready)
    }

    @Test
    fun aMachineWhoseLastContactFailedIsNotAsked() {
        assertFalse(TranscriptionCandidate.of(mac, transcribing, watched = false, lastContactFailed = true).ready)
    }

    @Test
    fun aMachineThatNeverAnsweredIsNotAsked() {
        assertFalse(TranscriptionCandidate.of(mac, null, watched = false, lastContactFailed = false).ready)
    }

    @Test
    fun withTheLinuxWindowOpenTheMacTranscribesOnceTheLinuxSaysItHasNoEngine() {
        val machines = listOf(
            TranscriptionCandidate.of(linux, transcribing, watched = true, lastContactFailed = false),
            TranscriptionCandidate.of(mac, transcribing, watched = false, lastContactFailed = false),
        )
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, machines, windowMachineID = "linux", localReady = true, refused = setOf("linux"))
        assertEquals("the Mac, not Whisper on the phone", TranscriptionEngine.HOST, route.engine)
        assertEquals(mac, route.machine)
        assertFalse(route.ofWindow)
    }

    @Test
    fun thePickedMacTranscribesForTheLinuxWindowWithoutBeingWatched() {
        val machines = listOf(
            TranscriptionCandidate.of(linux, transcribing, watched = true, lastContactFailed = false),
            TranscriptionCandidate.of(mac, transcribing, watched = false, lastContactFailed = false),
        )
        val route = TranscriptionRoute.decide(TranscriptionMode.MACHINE, machines, windowMachineID = "linux", chosenMachineID = "mac", localReady = true)
        assertEquals(mac, route.machine)
        assertEquals("a choice honoured needs no explanation", null, route.notice)
    }
}
