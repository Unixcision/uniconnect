package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Pixel 8 Pro case: the on-device engine has no Spanish model and gives up the instant it is
 * asked, which used to reach the reader as "no se ha entendido" before they had said a word.
 */
class RecogniserRecoveryTest {
    @Test
    fun anEngineThatGivesUpAtOnceIsTriedAgainOnTheNetworkOne() {
        assertTrue(
            "nothing could have been said in 40 ms",
            RecogniserRecovery.retryOnline(onDevice = true, triedOnline = false, heard = false, elapsedMillis = 40, failure = DictationFailure.NOT_UNDERSTOOD),
        )
    }

    @Test
    fun anEngineThatSaysItHasNoModelIsTriedAgainHoweverLongItTook() {
        assertTrue(RecogniserRecovery.retryOnline(onDevice = true, triedOnline = false, heard = false, elapsedMillis = 9_000, failure = DictationFailure.ENGINE_UNAVAILABLE))
    }

    @Test
    fun theNetworkRecogniserIsNotTriedTwiceNorFromItself() {
        assertFalse("it was already the second attempt", RecogniserRecovery.retryOnline(onDevice = true, triedOnline = true, heard = false, elapsedMillis = 40, failure = DictationFailure.NOT_UNDERSTOOD))
        assertFalse("the first attempt was already the network one", RecogniserRecovery.retryOnline(onDevice = false, triedOnline = false, heard = false, elapsedMillis = 40, failure = DictationFailure.NOT_UNDERSTOOD))
    }

    @Test
    fun anEngineThatUnderstoodSomethingIsNotAbandoned() {
        assertFalse(RecogniserRecovery.retryOnline(onDevice = true, triedOnline = false, heard = true, elapsedMillis = 40, failure = DictationFailure.NOT_UNDERSTOOD))
    }

    @Test
    fun aRealNotUnderstoodAfterListeningIsNotAnEngineProblem() {
        assertFalse("five seconds of silence is an answer about what was said", RecogniserRecovery.retryOnline(onDevice = true, triedOnline = false, heard = false, elapsedMillis = 5_000, failure = DictationFailure.NOT_UNDERSTOOD))
        assertFalse(RecogniserRecovery.silent(heard = false, elapsedMillis = 5_000, failure = DictationFailure.NOT_UNDERSTOOD))
    }

    @Test
    fun aFailureBeforeAWordCouldBeSaidIsWordedAsTheEngineNotAnswering() {
        listOf(DictationFailure.NOT_UNDERSTOOD, DictationFailure.ENGINE_UNAVAILABLE, DictationFailure.OTHER).forEach { failure ->
            assertTrue(failure.name, RecogniserRecovery.silent(heard = false, elapsedMillis = 120, failure = failure))
        }
    }

    @Test
    fun failuresWithATruthfulMessageOfTheirOwnKeepIt() {
        listOf(DictationFailure.NO_PERMISSION, DictationFailure.NO_NETWORK, DictationFailure.BUSY).forEach { failure ->
            assertFalse(failure.name, RecogniserRecovery.silent(heard = false, elapsedMillis = 120, failure = failure))
        }
        assertFalse("something was understood, so the engine did answer", RecogniserRecovery.silent(heard = true, elapsedMillis = 120, failure = DictationFailure.NOT_UNDERSTOOD))
    }

    @Test
    fun theBorderIsASecondAndAHalf() {
        assertEquals(1_500L, RecogniserRecovery.IMMEDIATE_MILLIS)
        assertTrue(RecogniserRecovery.silent(heard = false, elapsedMillis = RecogniserRecovery.IMMEDIATE_MILLIS - 1, failure = DictationFailure.NOT_UNDERSTOOD))
        assertFalse(RecogniserRecovery.silent(heard = false, elapsedMillis = RecogniserRecovery.IMMEDIATE_MILLIS, failure = DictationFailure.NOT_UNDERSTOOD))
    }
}
