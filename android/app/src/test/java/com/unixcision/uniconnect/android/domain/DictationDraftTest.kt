package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** Dictated text lands after what is already typed, never over it. */
class DictationDraftTest {
    @Test
    fun anEmptyDraftBecomesTheSpokenText() {
        assertEquals("git status", DictationDraft.append("", "git status"))
        assertEquals("git status", DictationDraft.append("   ", " git status "))
    }

    @Test
    fun spokenTextIsAppendedAfterOneSpaceNeverOverTheDraft() {
        assertEquals("ls -la hola", DictationDraft.append("ls -la", "hola"))
        assertEquals("ls -la hola", DictationDraft.append("ls -la  ", "hola"))
        assertEquals("primera\nlinea hola", DictationDraft.append("primera\nlinea", "hola"))
    }

    @Test
    fun nothingSpokenLeavesTheDraftAlone() {
        assertEquals("ls", DictationDraft.append("ls", "  "))
        assertEquals("", DictationDraft.append("", ""))
    }

    @Test
    fun aStoredLanguageNameReadsBackAndUnknownFallsToTheDevice() {
        assertEquals(DictationLanguage.ES_ES, DictationLanguage.named("ES_ES"))
        assertEquals("en-US", DictationLanguage.named("EN_US").tag)
        assertEquals(DictationLanguage.DEVICE, DictationLanguage.named("KLINGON"))
        assertEquals(null, DictationLanguage.DEVICE.tag)
    }
}
