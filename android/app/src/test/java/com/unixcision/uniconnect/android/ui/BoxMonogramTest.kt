package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.ui.components.boxTone
import com.unixcision.uniconnect.android.ui.components.monogram
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** The two letters and the colour a workspace is shown with, in the list and in its notices. */
class BoxMonogramTest {
    @Test
    fun twoWordsGiveTheirInitials() {
        assertEquals("QT", monogram("QA TMUX MOVIL"))
        assertEquals("GY", monogram("Gobierno y soporte"))
    }

    @Test
    fun oneWordGivesItsFirstTwoLetters() {
        assertEquals("TB", monogram("TB2BPRO"))
        assertEquals("CO", monogram("codex"))
    }

    @Test
    fun colourIsStableForANameAndCaseInsensitive() {
        assertEquals(boxTone("TB2BPRO"), boxTone("tb2bpro"))
        assertNotEquals(boxTone("TB2BPRO"), boxTone("Gobierno y soporte"))
    }
}
