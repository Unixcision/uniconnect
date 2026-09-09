package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which way an attachment goes and what may be pasted afterwards: a host that takes files gets
 * them directly, any other host sends the file to the fallback service announced on the sheet,
 * and a host copy that did not reach the SSH server is kept for copying, never pasted into the
 * remote window's draft.
 */
class AttachRouteTest {
    @Test
    fun aHostThatTakesFilesGetsThemOverThePrivateConnection() {
        assertEquals(AttachRoute.HOST, AttachRoute.forHost(takesFiles = true))
    }

    @Test
    fun aHostWithoutTheCapabilitySendsToTheFallbackService() {
        assertEquals(AttachRoute.EXTERNAL, AttachRoute.forHost(takesFiles = false))
    }

    @Test
    fun theRouteCapturedAtTheTapHoldsWhenThePickerReturns() {
        // Snapshot changed while the picker was open: the host took files, now it does not.
        assertEquals(AttachDecision.HostLostCapability, AttachDecision.onReturn(captured = AttachRoute.HOST, takesFilesNow = false))
        // Nothing changed: send as seen.
        assertEquals(AttachDecision.Send(AttachRoute.HOST), AttachDecision.onReturn(captured = AttachRoute.HOST, takesFilesNow = true))
        // The reader saw the fallback line and chose with it: the host gaining the capability meanwhile does not redirect the file.
        assertEquals(AttachDecision.Send(AttachRoute.EXTERNAL), AttachDecision.onReturn(captured = AttachRoute.EXTERNAL, takesFilesNow = true))
        assertEquals(AttachDecision.Send(AttachRoute.EXTERNAL), AttachDecision.onReturn(captured = AttachRoute.EXTERNAL, takesFilesNow = false))
    }

    @Test
    fun aLostCapabilityNeverBecomesAnExternalUpload() {
        val decision = AttachDecision.onReturn(captured = AttachRoute.HOST, takesFilesNow = false)
        assertFalse(decision is AttachDecision.Send)
    }

    @Test
    fun theTerminalFallbackFollowsEnviarArchivosUnlessChosen() {
        val page = UploadService("temp.sh", UploadStyle.MULTIPART_FILE)
        assertEquals(page, AppSettings(uploadService = page).terminalUpload)
        val own = UploadService("https://mi.servidor.com/api/upload", UploadStyle.MULTIPART_FILE)
        assertEquals(own, AppSettings(uploadService = page, terminalUploadService = own).terminalUpload)
    }

    @Test
    fun aFailedSshHopKeepsTheHostPathForCopyingAndDoesNotPasteIntoTheSshWindow() {
        val outcome = FilePutOutcome("/Users/d/UniConnect/Entrada/20260909/a.png", FilePutLocation.HOST, remotePath = null, remoteError = "scp: Connection refused")
        assertEquals("/Users/d/UniConnect/Entrada/20260909/a.png", outcome.pastePath)
        assertFalse(AttachPaste.shouldPaste(outcome.location, windowIsSSH = true, outcome.remoteError))
        assertFalse("even with the box kind unknown, the host's failed hop keeps it off the draft", AttachPaste.shouldPaste(outcome.location, windowIsSSH = null, outcome.remoteError))
        // The draft is what it was: nothing appended.
        val draft = "mira esto"
        val pasted = if (AttachPaste.shouldPaste(outcome.location, windowIsSSH = true, outcome.remoteError)) AttachPaste.pasteInto(draft, outcome.pastePath) else draft
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
