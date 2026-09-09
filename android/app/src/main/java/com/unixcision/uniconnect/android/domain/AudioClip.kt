package com.unixcision.uniconnect.android.domain

/**
 * One finished recording, wherever it was written. The dictation only ever reads it once and
 * deletes it; nothing outside keeps a copy, so a clip is gone the moment it is no longer needed,
 * whether it was transcribed, refused or cancelled.
 */
interface AudioClip {
    /** How much audio there is, in bytes; the size decides whether the contract accepts it. */
    val bytes: Long

    /** The whole recording, to be encoded and sent. */
    fun read(): ByteArray

    /** Removes it for good; calling twice is harmless. */
    fun delete()
}
