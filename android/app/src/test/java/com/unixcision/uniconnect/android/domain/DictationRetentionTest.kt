package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The history keeps the newest audio while it fits and drops older audio first, keeping its text;
 * whole entries go only beyond the record limit. The cleaner picks by age.
 */
class DictationRetentionTest {
    private fun record(id: String, at: Long, bytes: Long = 100, audio: Boolean = true) = DictationRecord(
        id = id, createdAt = at, text = "texto $id", state = DictationRecord.State.DONE,
        audioPath = if (audio) "/dictados/$id.m4a" else null, audioBytes = bytes, machineName = "Mac",
    )

    @Test
    fun withinTheLimitsNothingGoes() {
        assertTrue(DictationRetention.trim(listOf(record("a", 3), record("b", 2)), maxRecords = 5, maxAudioBytes = 1_000).isEmpty)
    }

    @Test
    fun theOldestAudioGoesFirstAndTheTextStays() {
        val newestFirst = listOf(record("nuevo", 3, 400), record("medio", 2, 400), record("viejo", 1, 400))
        val trim = DictationRetention.trim(newestFirst, maxRecords = 10, maxAudioBytes = 900)
        assertEquals(setOf("viejo"), trim.dropAudio)
        assertTrue(trim.dropRecords.isEmpty())
    }

    @Test
    fun onceTheBudgetIsSpentEveryOlderAudioGoesEvenASmallOne() {
        val newestFirst = listOf(record("nuevo", 3, 800), record("grande", 2, 500), record("pequeño", 1, 50))
        val trim = DictationRetention.trim(newestFirst, maxRecords = 10, maxAudioBytes = 900)
        assertEquals(setOf("grande", "pequeño"), trim.dropAudio)
    }

    @Test
    fun beyondTheRecordLimitTheOldestEntriesGoWhole() {
        val newestFirst = listOf(record("c", 3), record("b", 2), record("a", 1))
        val trim = DictationRetention.trim(newestFirst, maxRecords = 2, maxAudioBytes = 10_000)
        assertEquals(setOf("a"), trim.dropRecords)
        assertTrue(trim.dropAudio.isEmpty())
    }

    @Test
    fun theCleanerPicksByAgeOrEverything() {
        val day = DictationRetention.DAY_MILLIS
        val now = 10 * day
        val records = listOf(record("hoy", now - 1_000), record("semana", now - 8 * day), record("sin audio", now - 9 * day, audio = false))
        assertEquals(listOf("semana", "sin audio"), DictationRetention.olderThan(records, now, 7 * day).map { it.id })
        assertEquals(3, DictationRetention.olderThan(records, now, null).size)
        assertEquals(200L, DictationRetention.audioBytes(records))
    }
}
