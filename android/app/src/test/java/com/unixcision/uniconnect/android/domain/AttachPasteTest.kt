package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** How a path lands in the composer, and how the phone knows which way a file can go. */
class AttachPasteTest {
    @Test
    fun anEmptyDraftBecomesThePath() {
        assertEquals("/home/d/UniConnect/Entrada/a.png", AttachPaste.pasteInto("", "/home/d/UniConnect/Entrada/a.png"))
    }

    @Test
    fun textAlreadyTypedGetsOneSpaceThenThePath() {
        assertEquals("mira esto /tmp/a.png", AttachPaste.pasteInto("mira esto", "/tmp/a.png"))
        assertEquals("mira esto /tmp/a.png", AttachPaste.pasteInto("mira esto ", "/tmp/a.png"))
        assertEquals("linea\n/tmp/a.png", AttachPaste.pasteInto("linea\n", "/tmp/a.png"))
    }

    @Test
    fun aPathWithSpacesIsQuoted() {
        assertEquals("ver \"/tmp/mi foto.png\"", AttachPaste.pasteInto("ver", "/tmp/mi foto.png"))
        assertEquals("https://sendit.sh/x/y.txt", AttachPaste.pasteInto("", "https://sendit.sh/x/y.txt"))
    }

    @Test
    fun aRemoteCopyIsAlwaysPastedAndAHostCopyOnlyIntoALocalWindow() {
        assertTrue(AttachPaste.shouldPaste(FilePutLocation.REMOTE, windowIsSSH = true))
        assertTrue(AttachPaste.shouldPaste(FilePutLocation.REMOTE, windowIsSSH = false))
        assertTrue(AttachPaste.shouldPaste(FilePutLocation.HOST, windowIsSSH = false))
        assertTrue(AttachPaste.shouldPaste(FilePutLocation.HOST, windowIsSSH = null))
        assertFalse("a host copy is not where an SSH window's agent runs", AttachPaste.shouldPaste(FilePutLocation.HOST, windowIsSSH = true))
    }

    @Test
    fun theHostSaysWhetherItTakesFiles() {
        assertTrue(MachineSnapshot("Mac", emptyList(), setOf("box_update", "file_put.v1")).putsFiles)
        assertFalse(MachineSnapshot("Linux", emptyList(), setOf("box_update", "activity.v1")).putsFiles)
        assertFalse(MachineSnapshot("Viejo", emptyList()).putsFiles)
    }
}
