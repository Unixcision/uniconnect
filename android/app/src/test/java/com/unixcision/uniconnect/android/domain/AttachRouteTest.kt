package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two paths the cross review asked to see covered: nothing goes to an external service
 * without the reader's explicit choice, and a host copy that did not reach the SSH server is
 * kept for copying, never pasted into the remote window's draft.
 */
class AttachRouteTest {
    @Test
    fun withoutTheCapabilityAndWithoutAnExplicitChoiceNothingIsSent() {
        assertNull(AttachRoute.decide(takesFiles = false, chosenExternal = false))
    }

    @Test
    fun theExternalServiceIsOnlyReachedByTheExplicitChoice() {
        assertEquals(AttachRoute.EXTERNAL, AttachRoute.decide(takesFiles = false, chosenExternal = true))
    }

    @Test
    fun aHostThatTakesFilesAlwaysGetsThemOverThePrivateConnection() {
        assertEquals(AttachRoute.HOST, AttachRoute.decide(takesFiles = true, chosenExternal = false))
        assertEquals(AttachRoute.HOST, AttachRoute.decide(takesFiles = true, chosenExternal = true))
    }

    @Test
    fun aFailedSshHopKeepsTheHostPathForCopyingAndDoesNotPasteIntoTheSshWindow() {
        val outcome = FilePutOutcome("/Users/d/UniConnect/Entrada/20260909/a.png", FilePutLocation.HOST, remotePath = null, remoteError = "scp: Connection refused")
        assertEquals("/Users/d/UniConnect/Entrada/20260909/a.png", outcome.pastePath)
        assertFalse(AttachPaste.shouldPaste(outcome.location, windowIsSSH = true))
        // The draft is what it was: nothing appended.
        val draft = "mira esto"
        val pasted = if (AttachPaste.shouldPaste(outcome.location, windowIsSSH = true)) AttachPaste.pasteInto(draft, outcome.pastePath) else draft
        assertEquals("mira esto", pasted)
    }

    @Test
    fun aRemoteCopyIsPastedIntoTheSshWindowAndAHostCopyIntoALocalOne() {
        val remote = FilePutOutcome("/Users/d/UniConnect/Entrada/20260909/a.png", FilePutLocation.REMOTE, remotePath = "/home/d/uniconnect-entrada/a.png")
        assertTrue(AttachPaste.shouldPaste(remote.location, windowIsSSH = true))
        assertEquals("mira esto /home/d/uniconnect-entrada/a.png", AttachPaste.pasteInto("mira esto", remote.pastePath))
        val local = FilePutOutcome("/Users/d/UniConnect/Entrada/20260909/a.png", FilePutLocation.HOST)
        assertTrue(AttachPaste.shouldPaste(local.location, windowIsSSH = false))
        assertEquals("/Users/d/UniConnect/Entrada/20260909/a.png", AttachPaste.pasteInto("", local.pastePath))
    }
}
