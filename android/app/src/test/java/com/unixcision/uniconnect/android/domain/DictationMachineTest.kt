package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every transition of a dictation, without a microphone: partial to final, cancel, errors. */
class DictationMachineTest {
    @Test
    fun startingListensAndPartialsRefineWhatIsHeard() {
        val machine = DictationMachine()
        assertEquals(DictationState.Idle, machine.state.value)
        machine.onStarting()
        assertEquals(DictationState.Listening("", 0f), machine.state.value)
        machine.onPartial("ls")
        machine.onPartial("ls -la")
        assertEquals("ls -la", (machine.state.value as DictationState.Listening).partial)
    }

    @Test
    fun theLevelIsKeptBetweenZeroAndOne() {
        val machine = DictationMachine()
        machine.onStarting()
        machine.onLevel(-5f)
        assertEquals(0f, (machine.state.value as DictationState.Listening).level)
        machine.onLevel(4f)
        assertEquals(.5f, (machine.state.value as DictationState.Listening).level)
        machine.onLevel(30f)
        assertEquals(1f, (machine.state.value as DictationState.Listening).level)
        assertEquals(0f, DictationMachine.normalize(-2f))
        assertEquals(1f, DictationMachine.normalize(10f))
    }

    @Test
    fun aFinalResultEndsInDoneWithTheTextTrimmed() {
        val machine = DictationMachine()
        machine.onStarting()
        machine.onPartial("git sta")
        machine.onFinal("  git status ")
        assertEquals(DictationState.Done("git status"), machine.state.value)
    }

    @Test
    fun anEmptyFinalFallsBackToTheLastPartialOrIsNotUnderstood() {
        val withPartial = DictationMachine()
        withPartial.onStarting()
        withPartial.onPartial("git status")
        withPartial.onFinal("")
        assertEquals(DictationState.Done("git status"), withPartial.state.value)
        val silent = DictationMachine()
        silent.onStarting()
        silent.onFinal(null)
        assertEquals(DictationState.Failed(DictationFailure.NOT_UNDERSTOOD), silent.state.value)
    }

    @Test
    fun aNoMatchAfterSomethingWasHeardStillYieldsThatText() {
        val machine = DictationMachine()
        machine.onStarting()
        machine.onPartial("make test")
        machine.onError(DictationFailure.NOT_UNDERSTOOD)
        assertEquals(DictationState.Done("make test"), machine.state.value)
    }

    @Test
    fun otherErrorsAreReportedAsTheyAre() {
        listOf(DictationFailure.NO_NETWORK, DictationFailure.NO_PERMISSION, DictationFailure.BUSY, DictationFailure.ENGINE_UNAVAILABLE, DictationFailure.OTHER).forEach { failure ->
            val machine = DictationMachine()
            machine.onStarting()
            machine.onPartial("algo")
            machine.onError(failure)
            assertEquals(DictationState.Failed(failure), machine.state.value)
        }
    }

    @Test
    fun cancelThrowsEverythingAwayAndLateEventsAreIgnored() {
        val machine = DictationMachine()
        machine.onStarting()
        machine.onPartial("rm -rf")
        machine.cancel()
        assertEquals(DictationState.Idle, machine.state.value)
        machine.onFinal("rm -rf /")
        machine.onError(DictationFailure.NO_NETWORK)
        machine.onPartial("x")
        assertEquals("nothing after a cancel changes the state", DictationState.Idle, machine.state.value)
    }

    @Test
    fun resetReturnsToIdleAfterTheOutcomeWasTaken() {
        val machine = DictationMachine()
        machine.onStarting()
        machine.onFinal("hola")
        assertTrue(machine.state.value is DictationState.Done)
        machine.reset()
        assertEquals(DictationState.Idle, machine.state.value)
    }

    @Test
    fun aFailureOutsideListeningIsStillReported() {
        val machine = DictationMachine()
        machine.fail(DictationFailure.ENGINE_UNAVAILABLE)
        assertEquals(DictationState.Failed(DictationFailure.ENGINE_UNAVAILABLE), machine.state.value)
    }
}
