package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two models on offer: where each comes from, how big it is, and which one answers when both
 * are on the phone.
 */
class SpeechModelTest {
    @Test
    fun eachModelIsFetchedFromTheWhisperCppRepositoryUnderItsOwnName() {
        assertEquals("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin", SpeechModel.BASE.url)
        assertEquals("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin", SpeechModel.SMALL.url)
        assertTrue("nothing is fetched from anywhere else", SpeechModel.entries.all { it.url.startsWith(SpeechModel.HOST) })
    }

    @Test
    fun theSizesAreTheOnesADownloadIsMeasuredAgainst() {
        assertEquals(59_707_625, SpeechModel.BASE.bytes)
        assertEquals(190_085_487, SpeechModel.SMALL.bytes)
    }

    @Test
    fun theMagicIsGgmlSoAnythingElseIsNotAModel() {
        assertEquals("ggml", String(SpeechModel.MAGIC, Charsets.US_ASCII))
    }

    @Test
    fun theBetterModelAnswersWhenBothAreDownloaded() {
        assertNull(SpeechModel.best(emptySet()))
        assertEquals(SpeechModel.BASE, SpeechModel.best(setOf(SpeechModel.BASE)))
        assertEquals(SpeechModel.SMALL, SpeechModel.best(setOf(SpeechModel.SMALL)))
        assertEquals(SpeechModel.SMALL, SpeechModel.best(setOf(SpeechModel.BASE, SpeechModel.SMALL)))
    }

    @Test
    fun aStoredNameIsReadBackAndAnUnknownOneIsNothing() {
        assertEquals(SpeechModel.BASE, SpeechModel.named("BASE"))
        assertEquals(SpeechModel.SMALL, SpeechModel.named("SMALL"))
        assertNull(SpeechModel.named("MEDIUM"))
        assertNull(SpeechModel.named(null))
    }
}
