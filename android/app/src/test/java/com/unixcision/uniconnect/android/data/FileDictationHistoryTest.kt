package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioClip
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The history on disk: the audio is copied the moment the recording ends, so the engines can
 * delete their clip; the text arrives later; everything survives a restart, and an entry left
 * halfway by a crash comes back with its audio, as not transcribed.
 */
class FileDictationHistoryTest {
    private val directory: File = Files.createTempDirectory("dictados").toFile()
    private var now = 1_000L
    private val target = DictationTarget(Machine("m1", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!), "w1", "t1")

    @After
    fun cleanUp() { directory.deleteRecursively() }

    private fun history(maxAudioBytes: Long = 1_000_000) = FileDictationHistory(directory, clock = { now }, maxAudioBytes = maxAudioBytes)

    @Test
    fun theAudioIsKeptBeforeTranscribingAndOutlivesTheEnginesClip() {
        val history = history()
        val clip = FakeClip(byteArrayOf(1, 2, 3, 4))
        history.keep(clip, target)
        clip.delete()
        val record = history.records.value.single()
        assertEquals(DictationRecord.State.TRANSCRIBING, record.state)
        assertEquals("MacBook de Daniel", record.machineName)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), File(record.audioPath!!).readBytes())

        history.transcribed(clip, "el texto entero del dictado")
        assertEquals("el texto entero del dictado", history.records.value.single().text)
        assertEquals(DictationRecord.State.DONE, history.records.value.single().state)
    }

    @Test
    fun theSameClipHandedFromOneEngineToAnotherIsOneEntry() {
        val history = history()
        val clip = FakeClip(byteArrayOf(9))
        history.keep(clip, null)
        history.keep(clip, target)
        assertEquals(1, history.records.value.size)
        assertNull("kept first by the phone engine", history.records.value.single().machineName)
    }

    @Test
    fun aRecordingNoEngineReadStaysAsAudio() {
        val history = history()
        val clip = FakeClip(byteArrayOf(7, 7))
        history.keep(clip, target)
        history.unread(clip)
        val record = history.records.value.single()
        assertEquals(DictationRecord.State.UNREAD, record.state)
        assertNull(record.text)
        assertTrue(File(record.audioPath!!).exists())
    }

    @Test
    fun everythingSurvivesARestartAndAnInterruptedEntryComesBackAsUnread() {
        val first = history()
        val done = FakeClip(byteArrayOf(1))
        first.keep(done, target)
        first.transcribed(done, "hola")
        now = 2_000
        first.keep(FakeClip(byteArrayOf(2)), target)  // the app dies while this one is transcribing

        val reopened = history().records.value
        assertEquals(listOf(DictationRecord.State.UNREAD, DictationRecord.State.DONE), reopened.map { it.state })
        assertEquals("hola", reopened[1].text)
        assertTrue(reopened.all { it.audioPath != null && File(it.audioPath!!).exists() })
    }

    @Test
    fun deletingAnEntryRemovesItsAudioAndCleaningAudioKeepsTheText() {
        val history = history()
        val a = FakeClip(byteArrayOf(1)); val b = FakeClip(byteArrayOf(2))
        history.keep(a, target); history.transcribed(a, "uno")
        now = 2_000
        history.keep(b, target); history.transcribed(b, "dos")
        val (newest, oldest) = history.records.value
        history.deleteAudio(setOf(oldest.id))
        assertFalse(File(oldest.audioPath!!).exists())
        assertEquals("uno", history.records.value.last().text)
        assertNull(history.records.value.last().audioPath)

        history.delete(setOf(newest.id))
        assertFalse(File(newest.audioPath!!).exists())
        assertEquals(listOf("uno"), history().records.value.map { it.text })
    }

    @Test
    fun overTheAudioBudgetTheOldestAudioIsDroppedButItsTextStays() {
        val history = history(maxAudioBytes = 5)
        val old = FakeClip(ByteArray(3)); val fresh = FakeClip(ByteArray(3))
        history.keep(old, target); history.transcribed(old, "viejo")
        now = 2_000
        history.keep(fresh, target)
        val (newest, oldest) = history.records.value
        assertTrue(File(newest.audioPath!!).exists())
        assertNull(oldest.audioPath)
        assertEquals("viejo", oldest.text)
    }

    private class FakeClip(private val content: ByteArray) : AudioClip {
        private var deleted = false
        override val bytes: Long get() = content.size.toLong()
        override fun read(): ByteArray { check(!deleted); return content }
        override fun delete() { deleted = true }
    }
}
