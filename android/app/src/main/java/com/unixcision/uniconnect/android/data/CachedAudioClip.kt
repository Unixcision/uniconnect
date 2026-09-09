package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioClip
import java.io.File

/** A recording in the app's cache directory; reading it is one pass and deleting it is final. */
class CachedAudioClip(private val file: File) : AudioClip {
    override val bytes: Long get() = if (file.exists()) file.length() else 0

    override fun read(): ByteArray = file.readBytes()

    override fun delete() { runCatching { file.delete() } }
}
