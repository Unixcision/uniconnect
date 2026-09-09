package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Who transcribes, for every combination of the setting, the machine of the window and the other
 * machines. The machine of an open window is not always the one that should transcribe: a laptop
 * with a big model answers in a second where a small server takes a minute.
 */
class TranscriptionRouteTest {
    private val mac = machine("mac", "Mac de Dani")
    private val linux = machine("linux", "MINIPC")
    private val spare = machine("spare", "Portátil viejo")

    /** The window lives on the Linux box, which cannot transcribe; the Mac can and is connected. */
    private val mixed = listOf(
        TranscriptionCandidate(linux, transcribes = false, connected = true),
        TranscriptionCandidate(mac, transcribes = true, connected = true),
    )

    @Test
    fun theMachineOfTheWindowTranscribesWhenItCan() {
        val machines = listOf(TranscriptionCandidate(linux, transcribes = true, connected = true), TranscriptionCandidate(mac, transcribes = true, connected = true))
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, machines, windowMachineID = "linux")
        assertEquals(TranscriptionEngine.HOST, route.engine)
        assertEquals(linux, route.machine)
        assertTrue("its own machine, so the window travels with the audio", route.ofWindow)
        assertNull(route.notice)
    }

    @Test
    fun anotherConnectedMachineTranscribesForAWindowWhoseOwnCannot() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, mixed, windowMachineID = "linux")
        assertEquals(TranscriptionEngine.HOST, route.engine)
        assertEquals("the Mac answers for a terminal of the Linux box", mac, route.machine)
        assertFalse(route.ofWindow)
        assertNull("nothing to explain: it just works", route.notice)
    }

    @Test
    fun aMachineThatIsNotAnsweringIsNotAskedToTranscribe() {
        val asleep = listOf(
            TranscriptionCandidate(linux, transcribes = false, connected = true),
            TranscriptionCandidate(mac, transcribes = true, connected = false),
        )
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, asleep, windowMachineID = "linux")
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertEquals(TranscriptionNotice.HOST_CANNOT, route.notice)
        assertFalse("a fact about the machines is said once", route.notice!!.repeats)
    }

    @Test
    fun aMachineThatAnsweredUnsupportedIsSkippedFromThenOn() {
        val both = listOf(
            TranscriptionCandidate(linux, transcribes = true, connected = true),
            TranscriptionCandidate(mac, transcribes = true, connected = true),
        )
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, both, windowMachineID = "linux", refused = setOf("linux"))
        assertEquals("the window's own said it has no engine, so the Mac takes over", mac, route.machine)
        assertFalse(route.ofWindow)
        val none = TranscriptionRoute.decide(TranscriptionMode.AUTO, both, windowMachineID = "linux", refused = setOf("linux", "mac"))
        assertEquals(TranscriptionEngine.PHONE, none.engine)
        assertEquals(TranscriptionNotice.HOST_CANNOT, none.notice)
    }

    @Test
    fun withNoMachineAbleThePhoneDictates() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, listOf(TranscriptionCandidate(linux, transcribes = false, connected = true)), windowMachineID = "linux")
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertNull(route.machine)
        assertEquals(TranscriptionNotice.HOST_CANNOT, route.notice)
    }

    @Test
    fun withoutAnOpenWindowAnyConnectedMachineStillTranscribes() {
        val route = TranscriptionRoute.decide(TranscriptionMode.AUTO, mixed, windowMachineID = null)
        assertEquals(mac, route.machine)
        assertFalse(route.ofWindow)
    }

    @Test
    fun alwaysOnThePhoneNeverAsksAnyMachineNorExplainsItself() {
        val route = TranscriptionRoute.decide(TranscriptionMode.PHONE, mixed, windowMachineID = "linux")
        assertEquals(TranscriptionEngine.PHONE, route.engine)
        assertNull(route.machine)
        assertNull(route.notice)
    }

    @Test
    fun alwaysOnTheWindowsMachineDoesNotWanderToAnother() {
        val able = TranscriptionRoute.decide(TranscriptionMode.HOST, listOf(TranscriptionCandidate(linux, transcribes = true, connected = true)), windowMachineID = "linux")
        assertEquals(linux, able.machine)
        assertTrue(able.ofWindow)
        val unable = TranscriptionRoute.decide(TranscriptionMode.HOST, mixed, windowMachineID = "linux")
        assertEquals("the Mac could, but the reader asked for the window's own", TranscriptionEngine.PHONE, unable.engine)
        assertEquals(TranscriptionNotice.HOST_REQUIRED_UNAVAILABLE, unable.notice)
        assertTrue("an unmet explicit choice is said every time", unable.notice!!.repeats)
    }

    @Test
    fun onePickedMachineTranscribesWhicheverWindowIsOpen() {
        val route = TranscriptionRoute.decide(TranscriptionMode.MACHINE, mixed, windowMachineID = "linux", chosenMachineID = "mac")
        assertEquals(mac, route.machine)
        assertFalse(route.ofWindow)
        assertNull(route.notice)
    }

    @Test
    fun thePickedMachineMayBeTheWindowsOwn() {
        val machines = listOf(TranscriptionCandidate(linux, transcribes = true, connected = true))
        val route = TranscriptionRoute.decide(TranscriptionMode.MACHINE, machines, windowMachineID = "linux", chosenMachineID = "linux")
        assertEquals(linux, route.machine)
        assertTrue("the window travels because that machine owns it", route.ofWindow)
    }

    @Test
    fun aPickedMachineThatCannotFallsBackToTheAutomaticRuleAndSaysSoOnce() {
        val asleep = listOf(
            TranscriptionCandidate(linux, transcribes = false, connected = true),
            TranscriptionCandidate(mac, transcribes = true, connected = true),
            TranscriptionCandidate(spare, transcribes = true, connected = false),
        )
        val route = TranscriptionRoute.decide(TranscriptionMode.MACHINE, asleep, windowMachineID = "linux", chosenMachineID = "spare")
        assertEquals("the automatic rule ran and found the Mac", mac, route.machine)
        assertEquals(TranscriptionNotice.CHOSEN_UNAVAILABLE, route.notice)
        assertFalse(route.notice!!.repeats)
    }

    @Test
    fun aPickedMachineThatIsGoneOrNeverChosenIsTheSameFallback() {
        listOf(null, "borrada").forEach { chosen ->
            val route = TranscriptionRoute.decide(TranscriptionMode.MACHINE, mixed, windowMachineID = "linux", chosenMachineID = chosen)
            assertEquals("$chosen", mac, route.machine)
            assertEquals("$chosen", TranscriptionNotice.CHOSEN_UNAVAILABLE, route.notice)
        }
        val nothing = TranscriptionRoute.decide(TranscriptionMode.MACHINE, listOf(TranscriptionCandidate(linux, transcribes = false, connected = true)), windowMachineID = "linux", chosenMachineID = "mac")
        assertEquals(TranscriptionEngine.PHONE, nothing.engine)
        assertEquals("the picked machine is the one worth explaining", TranscriptionNotice.CHOSEN_UNAVAILABLE, nothing.notice)
    }

    @Test
    fun theWindowTravelsOnlyWithTheMachineThatOwnsIt() {
        val window = DictationTarget(linux, "ws-1", "win-1")
        val own = TranscriptionRoute(TranscriptionEngine.HOST, linux, ofWindow = true).target(window)
        assertEquals(linux, own?.machine)
        assertEquals("ws-1", own?.workspaceID)
        assertEquals("win-1", own?.terminalID)
        val other = TranscriptionRoute(TranscriptionEngine.HOST, mac, ofWindow = false).target(window)
        assertEquals(mac, other?.machine)
        assertNull("a machine that does not own the window is asked for text and nothing else", other?.workspaceID)
        assertNull(other?.terminalID)
        assertNull("nothing to aim at when the phone listens", TranscriptionRoute(TranscriptionEngine.PHONE).target(window))
    }

    @Test
    fun aMicrophoneIsOfferedWhenEitherSideCanListen() {
        val toAMachine = TranscriptionRoute(TranscriptionEngine.HOST, mac)
        assertTrue("a machine transcribes even where the phone has no recogniser", toAMachine.canDictate(phoneAvailable = false))
        val toThePhone = TranscriptionRoute(TranscriptionEngine.PHONE)
        assertTrue(toThePhone.canDictate(phoneAvailable = true))
        assertFalse("nothing can listen", toThePhone.canDictate(phoneAvailable = false))
    }

    @Test
    fun aPhoneWithoutARecogniserIsNotToldAboutAFallbackItCannotUse() {
        val none = listOf(TranscriptionCandidate(linux, transcribes = false, connected = true))
        assertNull(TranscriptionRoute.decide(TranscriptionMode.AUTO, none, windowMachineID = "linux", phoneAvailable = false).notice)
    }

    @Test
    fun aStoredModeSurvivesAndAnythingUnknownIsAutomatic() {
        assertEquals(TranscriptionMode.HOST, TranscriptionMode.named("HOST"))
        assertEquals(TranscriptionMode.PHONE, TranscriptionMode.named("PHONE"))
        assertEquals(TranscriptionMode.MACHINE, TranscriptionMode.named("MACHINE"))
        assertEquals(TranscriptionMode.AUTO, TranscriptionMode.named(null))
        assertEquals(TranscriptionMode.AUTO, TranscriptionMode.named("WHISPER"))
    }

    private fun machine(id: String, name: String) = Machine(id, name, MachineEndpoint.parse("100.64.0.1", "58465")!!)
}
