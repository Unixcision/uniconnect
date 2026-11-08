package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Un enganche automático que falla por algo pasajero se repite; uno que no va a cambiar, no. */
class TerminalAttachRetryTest {
    @Test
    fun passingFailuresAreRetriedTwiceWithAGrowingPause() {
        assertEquals(800L, TerminalAttachRetry.nextDelayMillis(1, MachineFailure.Transport()))
        assertEquals(1_600L, TerminalAttachRetry.nextDelayMillis(2, MachineFailure.DeadlineExceeded()))
        assertNull(TerminalAttachRetry.nextDelayMillis(3, MachineFailure.Transport()))
        assertEquals(800L, TerminalAttachRetry.nextDelayMillis(1, MachineFailure.TerminalNotReady()))
        assertEquals(800L, TerminalAttachRetry.nextDelayMillis(1, java.net.SocketTimeoutException()))
        assertEquals(800L, TerminalAttachRetry.nextDelayMillis(1, MachineFailure.Rejected("session_missing")))
    }

    @Test
    fun failuresThatWillNotChangeAreNotRetried() {
        for (code in listOf("method_not_found", "unknown_method", "not_durable", "approval_required", "unsupported")) {
            assertNull(code, TerminalAttachRetry.nextDelayMillis(1, MachineFailure.Rejected(code)))
        }
        assertNull(TerminalAttachRetry.nextDelayMillis(1, MachineFailure.ProtocolMismatch()))
    }
}
