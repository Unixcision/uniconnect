package com.unixcision.uniconnect.android.domain

/**
 * How big the dictation history may grow, and what the cleaner touches.
 *
 * Audio is what weighs, so it goes first, oldest first, and the text of those entries stays.
 * Whole entries are removed only beyond the record limit.
 */
object DictationRetention {
    const val MAX_RECORDS = 300
    const val MAX_AUDIO_BYTES = 300L * 1024 * 1024
    const val DAY_MILLIS = 24L * 60 * 60 * 1000

    /** What has to go: [dropRecords] entirely, [dropAudio] only their audio. */
    data class Trim(val dropRecords: Set<String>, val dropAudio: Set<String>) {
        val isEmpty: Boolean get() = dropRecords.isEmpty() && dropAudio.isEmpty()
    }

    /**
     * What to remove from [records] (newest first) to stay within the limits: the newest
     * entries keep their audio while it fits in [maxAudioBytes], everything older loses it.
     */
    fun trim(records: List<DictationRecord>, maxRecords: Int = MAX_RECORDS, maxAudioBytes: Long = MAX_AUDIO_BYTES): Trim {
        val dropRecords = records.drop(maxRecords).mapTo(mutableSetOf()) { it.id }
        val dropAudio = mutableSetOf<String>()
        var used = 0L
        var full = false
        for (record in records) {
            if (record.id in dropRecords || record.audioPath == null) continue
            if (!full && used + record.audioBytes <= maxAudioBytes) used += record.audioBytes
            else { full = true; dropAudio += record.id }
        }
        return Trim(dropRecords, dropAudio)
    }

    /** Entries older than [olderThanMillis] at [now], or every entry when it is null. */
    fun olderThan(records: List<DictationRecord>, now: Long, olderThanMillis: Long?): List<DictationRecord> =
        if (olderThanMillis == null) records else records.filter { now - it.createdAt > olderThanMillis }

    /** Bytes of audio those entries still keep. */
    fun audioBytes(records: List<DictationRecord>): Long = records.sumOf { if (it.audioPath != null) it.audioBytes else 0L }
}
