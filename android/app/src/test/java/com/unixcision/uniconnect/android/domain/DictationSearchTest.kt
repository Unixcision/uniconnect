package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The search box finds dictations however they were typed: no case, no accents, any word order. */
class DictationSearchTest {
    private val record = DictationRecord(
        id = "1", createdAt = 0, text = "Revisa la canción del vídeo y súbela a PRODUCCIÓN mañana",
        state = DictationRecord.State.DONE, audioPath = null, audioBytes = 0, machineName = "MacBook de Daniel",
    )

    @Test
    fun anEmptyQueryShowsEverything() {
        assertTrue(DictationSearch.matches(record, ""))
        assertTrue(DictationSearch.matches(record, "   "))
    }

    @Test
    fun caseAndAccentsDoNotMatter() {
        assertTrue(DictationSearch.matches(record, "cancion"))
        assertTrue(DictationSearch.matches(record, "produccion"))
        assertTrue(DictationSearch.matches(record, "VÍDEO"))
    }

    @Test
    fun everyWordMustAppearInAnyOrder() {
        assertTrue(DictationSearch.matches(record, "mañana video"))
        assertFalse(DictationSearch.matches(record, "mañana borrar"))
    }

    @Test
    fun theMachineNameIsSearchedToo() {
        assertTrue(DictationSearch.matches(record, "macbook"))
        assertFalse(DictationSearch.matches(record.copy(text = null), "cancion"))
    }
}
