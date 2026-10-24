package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.StateFlow

/**
 * Where every recording is kept, with its text once it has one.
 *
 * The dictation engines report each recording here as soon as it ends, before it is sent, so a
 * transcription that fails, a crash or a send that goes wrong never costs what was said. Calls
 * about the same [AudioClip] refer to the same entry, also when one engine hands the clip to
 * another. [keep] copies the audio at once, so the engines may delete their clip right after.
 */
interface DictationHistory {
    /** Newest first. */
    val records: StateFlow<List<DictationRecord>>

    /** Keeps a copy of [clip] as a new entry being transcribed; a clip already kept is ignored. */
    fun keep(clip: AudioClip, target: DictationTarget?)

    /** Stores what an engine understood from [clip]. */
    fun transcribed(clip: AudioClip, text: String)

    /** Marks [clip] as read by no engine: failed, cancelled or given up on. Its audio stays. */
    fun unread(clip: AudioClip)

    /** Replaces the text of entry [id] with a new transcription of its audio. */
    fun replaceText(id: String, text: String)

    /** Removes these entries with their audio. */
    fun delete(ids: Set<String>)

    /** Removes only the audio of these entries; their text stays. */
    fun deleteAudio(ids: Set<String>)
}
