package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

class ComposerActionTest {
    @Test
    fun `an empty draft offers the microphone`() {
        assertEquals(ComposerAction.DICTATE, ComposerAction.decide("", dictationAvailable = true))
    }

    @Test
    fun `a draft with text sends`() {
        assertEquals(ComposerAction.SEND, ComposerAction.decide("ls", dictationAvailable = true))
    }

    @Test
    fun `deleting every character brings the microphone back even when a line break is left over`() {
        // The keyboard's Enter writes a line break into the draft: erasing the words can leave it
        // behind, and the box looks empty while the button stayed on send.
        assertEquals(ComposerAction.DICTATE, ComposerAction.decide("\n", dictationAvailable = true))
        assertEquals(ComposerAction.DICTATE, ComposerAction.decide("   ", dictationAvailable = true))
        assertEquals(ComposerAction.DICTATE, ComposerAction.decide(" \n ", dictationAvailable = true))
    }

    @Test
    fun `without speech recognition the button always sends`() {
        assertEquals(ComposerAction.SEND, ComposerAction.decide("", dictationAvailable = false))
        assertEquals(ComposerAction.SEND, ComposerAction.decide("ls", dictationAvailable = false))
    }

    @Test
    fun `a blank draft is nothing to send`() {
        assertEquals(false, ComposerAction.hasSomethingToSend("\n"))
        assertEquals(false, ComposerAction.hasSomethingToSend("  "))
        assertEquals(true, ComposerAction.hasSomethingToSend(" ls "))
    }
}
