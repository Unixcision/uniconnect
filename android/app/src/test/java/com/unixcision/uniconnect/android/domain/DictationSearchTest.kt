package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The search box finds dictations and messages however they were typed: no case, no accents, no
 * punctuation, any word order, pieces of words and a typo in a long word; the closest comes first.
 */
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
    fun aTypoInALongWordStillFindsIt() {
        val dictated = record.copy(text = "Vuelve a lanzar la transcripción del audio largo")
        assertTrue(DictationSearch.matches(dictated, "trasncripcion"))
        assertTrue(DictationSearch.matches(dictated, "trascripcion"))
        assertTrue(DictationSearch.matches(dictated, "trasncrip"))
        assertTrue(DictationSearch.matches(record, "produccon"))
        // A short word has to be right: «vpn» is not «vps».
        assertFalse(DictationSearch.matches(record.copy(text = "sube el vps"), "vpn"))
    }

    @Test
    fun punctuationAndPiecesOfWordsDoNotGetInTheWay() {
        val message = SentMessage("m", 0, "¿Ya le has dado al VPS, los archivos para tspay?", true, SentMessage.State.DELIVERED, "MacBook de Daniel", "APP 2")
        assertTrue(DictationSearch.matches(message, "vps los"))
        assertTrue(DictationSearch.matches(message, "archiv tspay"))
        assertTrue(DictationSearch.matches(message, "app 2"))
    }

    @Test
    fun theClosestComesFirstAndTiesKeepTheNewestFirst() {
        val exact = record.copy(id = "exacto", text = "sube a producción mañana")
        val scattered = record.copy(id = "suelto", text = "mañana revisa y sube lo de producción")
        val typo = record.copy(id = "errata", text = "sube a produccon mañana")
        val older = record.copy(id = "viejo", text = "sube a producción mañana")
        val ranked = DictationSearch.rankDictations(listOf(typo, scattered, exact, older), "sube a produccion")
        assertEquals(listOf("exacto", "viejo", "suelto", "errata"), ranked.map { it.id })
        assertEquals(4, DictationSearch.rankDictations(ranked, "").size)
    }

    @Test
    fun theMachineNameIsSearchedToo() {
        assertTrue(DictationSearch.matches(record, "macbook"))
        assertFalse(DictationSearch.matches(record.copy(text = null), "cancion"))
    }
}
