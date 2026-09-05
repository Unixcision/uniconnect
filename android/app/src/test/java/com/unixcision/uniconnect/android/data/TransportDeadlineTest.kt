package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.MachineFailure

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class TransportDeadlineTest {
    @Test fun ownNetworkTimeoutIsAFailureThatTheUiCanRecoverFrom() {
        runBlocking {
            try {
                transportDeadline(5) { awaitCancellation() }
                fail("The deadline must terminate a stalled operation")
            } catch (_: MachineFailure.DeadlineExceeded) {
                // Ordinary Exception, not CancellationException: reconnect and clear pending mutation state.
            }
        }
    }

    @Test fun cancellationByTheOwnerMustNotBecomeAnAutomaticRetry() {
        runBlocking {
            try {
                withTimeout(5) { transportDeadline(10_000) { awaitCancellation() } }
                fail("The owning workflow must cancel")
            } catch (_: TimeoutCancellationException) {
                // The outer cancellation is preserved instead of being mistaken for a network failure.
            }
        }
    }

    @Test fun successfulResponsesKeepTheirValue() {
        runBlocking { assertEquals(42, transportDeadline(1_000) { 42 }) }
    }
}
