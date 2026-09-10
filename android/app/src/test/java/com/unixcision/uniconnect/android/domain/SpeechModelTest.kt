package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertArrayEquals
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

    @Test
    fun theMagicIsTheBytesAsTheyLieOnDiskNotTheWordSpelledOut() {
        // Taken from the head of the real ggml-base-q5_1.bin published by whisper.cpp. ggml writes
        // its magic as the number 0x67676d6c on a little-endian machine, so the file starts with
        // `lmgg`. Written the readable way round, every model that downloads correctly is thrown
        // away as corrupt and the next attempt asks the server to resume past the end of the file,
        // which answers 416 for ever.
        val headOfARealModel = byteArrayOf(0x6c, 0x6d, 0x67, 0x67, 0x99.toByte(), 0xca.toByte(), 0x00, 0x00)
        assertArrayEquals(SpeechModel.MAGIC, headOfARealModel.copyOf(SpeechModel.MAGIC.size))
    }
}
