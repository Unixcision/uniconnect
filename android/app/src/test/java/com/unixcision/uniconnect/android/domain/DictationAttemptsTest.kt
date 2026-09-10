package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What keeps a cancelled dictation cancelled. A recogniser answers whenever it wants, and the
 * retry queued for a failed try runs later than the cancel that came in between: without a number
 * per try, that retry reopened the microphone after the reader had cancelled.
 */
class DictationAttemptsTest {
    @Test
    fun theTryThatStartedLastIsTheLiveOne() {
        val attempts = DictationAttempts()
        val first = attempts.begin()
        assertTrue(attempts.isLive(first))
        val second = attempts.begin()
        assertTrue(attempts.isLive(second))
        assertFalse("a dictation started again leaves the previous one behind", attempts.isLive(first))
    }

    @Test
    fun cancellingBetweenTheFailureAndItsRetryDropsTheRetry() {
        val attempts = DictationAttempts()
        val dictation = attempts.begin()
        // The engine gave up and queued a retry carrying this same number...
        attempts.abandon()
        assertFalse("...but the reader cancelled first, so it opens nothing", attempts.isLive(dictation))
    }

    @Test
    fun aLateResultOfAnAbandonedTryIsNotPublished() {
        val attempts = DictationAttempts()
        val dictation = attempts.begin()
        attempts.abandon()
        assertFalse("the screen already moved on", attempts.isLive(dictation))
        val next = attempts.begin()
        assertTrue(next != dictation)
        assertFalse("and the old one never becomes live again", attempts.isLive(dictation))
    }

    @Test
    fun nothingIsLiveBeforeADictationStarts() {
        val attempts = DictationAttempts()
        assertFalse(attempts.isLive(1))
        assertFalse(attempts.isLive(0))
    }
}
