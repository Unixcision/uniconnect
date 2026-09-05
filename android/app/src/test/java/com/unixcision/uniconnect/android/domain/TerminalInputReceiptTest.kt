package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalInputReceiptTest {
    private val target = TerminalTarget("workspace-a", "window-a")

    @Test fun successfulImmediateDeliveryDoesNotBecomeAFailedOrRetriedInput() {
        assertTrue(TerminalInputReceipt.accepts(target, target, queued = false))
        assertTrue(TerminalInputReceipt.accepts(target, target, queued = true))
    }

    @Test fun missingDeliveryStateOrAnotherTargetCannotAcknowledgeThisInput() {
        assertFalse(TerminalInputReceipt.accepts(target, target, queued = null))
        assertFalse(TerminalInputReceipt.accepts(target, target.copy(windowID = "other-window"), queued = false))
        assertFalse(TerminalInputReceipt.accepts(target, target.copy(workspaceID = "other-workspace"), queued = true))
    }
}
