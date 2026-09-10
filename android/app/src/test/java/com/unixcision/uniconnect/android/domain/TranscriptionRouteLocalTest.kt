package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Who transcribes once Whisper can also run on the phone.
 *
 * The order the reader was promised is: the machine of the window, any other machine that can,
 * Whisper here, and only then the recogniser Android ships with. Every way of asking for something
 * else is checked, and so is the promise that nothing is ever routed to an engine that cannot run.
 */
class TranscriptionRouteLocalTest {
    private val mac = machine("mac", "Mac de Dani")
    private val linux = machine("linux", "MINIPC")

    private val windowCan = listOf(
        TranscriptionCandidate(linux, transcribes = true, connected = true),
        TranscriptionCandidate(mac, transcribes = true, connected = true),
    )
    private val onlyOtherCan = listOf(
        TranscriptionCandidate(linux, transcribes = false, connected = true),
        TranscriptionCandidate(mac, transcribes = true, connected = true),
    )
    private val noneCan = listOf(
        TranscriptionCandidate(linux, transcribes = false, connected = true),
        TranscriptionCandidate(mac, transcribes = true, connected = false),
    )

    @Test
    fun aMachineStillComesBeforeWhisperOnThePhone() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, windowCan, windowMachineID = "linux", localReady = true)
        assertEquals("a laptop reads a minute of speech in a second and a phone does not", TranscriptionEngine.HOST, route.engine)
        assertEquals(linux, route.machine)
        assertTrue(route.ofWindow)
        assertNull(route.notice)
    }

    @Test
    fun anotherMachineAlsoComesBeforeWhisperOnThePhone() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, onlyOtherCan, windowMachineID = "linux", localReady = true)
        assertEquals(TranscriptionEngine.HOST, route.engine)
        assertEquals(mac, route.machine)
        assertFalse(route.ofWindow)
    }

    @Test
    fun whisperOnThePhoneTakesOverWhenNoMachineCan() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, noneCan, windowMachineID = "linux", localReady = true)
        assertEquals(TranscriptionEngine.LOCAL, route.engine)
        assertNull("nothing travels anywhere, so there is no machine", route.machine)
        assertNull("this is the rule working, not a fallback worth explaining", route.notice)
    }

    @Test
    fun withoutAModelTheAutomaticRuleEndsOnTheSystemRecogniser() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, noneCan, windowMachineID = "linux", localReady = false)
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertEquals(TranscriptionNotice.HOST_CANNOT, route.notice)
    }

    @Test
    fun askingForWhisperOnThePhoneGetsItEvenWhenEveryMachineCould() {
        val route = TranscriptionRoute.decide(TranscriptionMode.LOCAL, windowCan, windowMachineID = "linux", localReady = true)
        assertEquals(TranscriptionEngine.LOCAL, route.engine)
        assertNull(route.notice)
    }

    @Test
    fun askingForWhisperWithoutAModelFallsToTheAutomaticRuleAndSaysSoOnce() {
        val route = TranscriptionRoute.decide(TranscriptionMode.LOCAL, onlyOtherCan, windowMachineID = "linux", localReady = false)
        assertEquals("the Mac can, so the recording is not wasted on the recogniser", TranscriptionEngine.HOST, route.engine)
        assertEquals(mac, route.machine)
        assertEquals(TranscriptionNotice.LOCAL_UNAVAILABLE, route.notice)
        assertTrue("an order that could not be honoured is said every single time", route.notice!!.repeats)
    }

    @Test
    fun askingForWhisperWithoutAModelAndWithoutAMachineEndsOnTheRecogniser() {
        val route = TranscriptionRoute.decide(TranscriptionMode.LOCAL, noneCan, windowMachineID = "linux", localReady = false)
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertEquals(TranscriptionNotice.LOCAL_UNAVAILABLE, route.notice)
    }

    @Test
    fun aPickedMachineThatCannotFallsThroughWhisperBeforeTheRecogniser() {
        val route = TranscriptionRoute.decide(
            TranscriptionMode.MACHINE, noneCan, windowMachineID = "linux", chosenMachineID = "mac", localReady = true,
        )
        assertEquals(TranscriptionEngine.LOCAL, route.engine)
        assertEquals(TranscriptionNotice.CHOSEN_UNAVAILABLE, route.notice)
    }

    @Test
    fun askingForTheSystemRecogniserGetsItWhateverElseIsAvailable() {
        val route = TranscriptionRoute.decide(TranscriptionMode.PHONE, windowCan, windowMachineID = "linux", localReady = true)
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertNull("it is what was asked for; nothing to explain", route.notice)
    }

    @Test
    fun aMicrophoneIsWorthOfferingWhenWhisperCanRunEvenWithoutARecogniser() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, noneCan, windowMachineID = "linux", phoneAvailable = false, localReady = true)
        assertEquals(TranscriptionEngine.LOCAL, route.engine)
        assertTrue("a phone with a model needs no recogniser", route.canDictate(phoneAvailable = false))
    }

    @Test
    fun whisperOnThePhoneSendsTheRecordingNowhere() {
        val route = TranscriptionRoute.decide(TranscriptionMode.LOCAL, windowCan, windowMachineID = "linux", localReady = true)
        val window = DictationTarget(linux, "w1", "t1")
        assertNull("nothing leaves the phone, so there is no target", route.target(window))
    }

    /**
     * Over every combination of setting, machines, model and recogniser: the engine chosen is
     * always one that can actually run.
     *
     * It is the invariant the whole rule exists for. A phone routed to a machine that is not
     * answering, or to a model that is not downloaded, loses what the reader just said.
     */
    @Test
    fun noCombinationEverRoutesToAnEngineThatCannotRun() {
        val machineSets = mapOf("window can" to windowCan, "only another can" to onlyOtherCan, "none can" to noneCan, "no machines" to emptyList())
        for (mode in TranscriptionMode.entries) {
            for ((label, machines) in machineSets) {
                for (localReady in listOf(true, false)) {
                    for (phoneAvailable in listOf(true, false)) {
                        for (chosen in listOf(null, "mac", "ghost")) {
                            val route = TranscriptionRoute.decide(mode, machines, "linux", chosen, phoneAvailable, localReady)
                            val where = "$mode over $label, model=$localReady, recogniser=$phoneAvailable, picked=$chosen"
                            when (route.engine) {
                                TranscriptionEngine.HOST -> {
                                    val candidate = machines.firstOrNull { it.machine.id == route.machine?.id }
                                    assertTrue("$where routed to a machine that cannot take it", candidate?.ready == true)
                                }
                                TranscriptionEngine.LOCAL -> assertTrue("$where routed to a model that is not there", localReady)
                                TranscriptionEngine.PHONE -> Unit
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    fun anOrderIsNeverQuietlyImprovedUpon() {
        // Every fixed way of transcribing, against machines that could do it better, with a model
        // downloaded and a recogniser available: the engine that runs is the one that was ordered.
        for (machines in listOf(windowCan, onlyOtherCan, noneCan)) {
            val local = TranscriptionRoute.decide(TranscriptionMode.LOCAL, machines, "linux", "mac", phoneAvailable = true, localReady = true)
            assertEquals("$machines", TranscriptionEngine.LOCAL, local.engine)
            assertNull("nothing to explain: it is what was ordered", local.notice)

            val recogniser = TranscriptionRoute.decide(TranscriptionMode.PHONE, machines, "linux", "mac", phoneAvailable = true, localReady = true)
            assertEquals("$machines", TranscriptionEngine.PHONE, recogniser.engine)
            assertNull(recogniser.notice)
        }
        // The picked machine answers even when the window's own could, and even with a model here.
        val picked = TranscriptionRoute.decide(TranscriptionMode.MACHINE, windowCan, "linux", "mac", phoneAvailable = true, localReady = true)
        assertEquals(mac, picked.machine)
        assertFalse("the window's machine is not better than an order", picked.ofWindow)
        assertNull(picked.notice)
    }

    @Test
    fun theWindowsOwnMachineCanBeTheOneOrdered() {
        val picked = TranscriptionRoute.decide(TranscriptionMode.MACHINE, windowCan, "linux", "linux", localReady = true)
        assertEquals(linux, picked.machine)
        assertTrue("its own window, so the identifiers travel with the audio", picked.ofWindow)
        assertNull(picked.notice)
    }

    @Test
    fun anOrderOnlyGivesWayWhenItsEngineCannotRun() {
        // Whisper here with no model, and the picked machine asleep: the only two ways out.
        val noModel = TranscriptionRoute.decide(TranscriptionMode.LOCAL, windowCan, "linux", localReady = false)
        assertEquals(TranscriptionNotice.LOCAL_UNAVAILABLE, noModel.notice)
        val asleep = TranscriptionRoute.decide(TranscriptionMode.MACHINE, noneCan, "linux", chosenMachineID = "mac", localReady = true)
        assertEquals(TranscriptionNotice.CHOSEN_UNAVAILABLE, asleep.notice)
        assertTrue("both are said every time they happen", noModel.notice!!.repeats && asleep.notice!!.repeats)
    }

    @Test
    fun whoRanInsteadIsAlwaysNameableForTheLineThatExplainsIt() {
        val toAMachine = TranscriptionRoute.decide(TranscriptionMode.LOCAL, onlyOtherCan, "linux", localReady = false)
        assertEquals(Transcriber.OtherMachine("Mac de Dani"), toAMachine.ran)
        val toWhisper = TranscriptionRoute.decide(TranscriptionMode.MACHINE, noneCan, "linux", chosenMachineID = "mac", localReady = true)
        assertEquals(Transcriber.PhoneWhisper, toWhisper.ran)
        val toTheRecogniser = TranscriptionRoute.decide(TranscriptionMode.LOCAL, noneCan, "linux", localReady = false)
        assertEquals(Transcriber.PhoneRecogniser, toTheRecogniser.ran)
        // Even the window's own machine is nameable here: the bar hides it, an explanation does not.
        val ownWindow = TranscriptionRoute.decide(TranscriptionMode.AUTO, windowCan, "linux")
        assertEquals(Transcriber.OtherMachine("MINIPC"), ownWindow.ran)
    }

    private fun machine(id: String, name: String) = Machine(id, name, MachineEndpoint.parse("100.64.0.1", "58465")!!)
}
