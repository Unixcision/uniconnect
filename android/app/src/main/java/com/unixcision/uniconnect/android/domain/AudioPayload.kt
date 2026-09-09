package com.unixcision.uniconnect.android.domain

import java.util.Base64

/**
 * How a recording travels inside `mobile.audio.transcribe`: base64 in one JSON frame.
 *
 * The contract refuses over 6 MiB, and a frame of this transport is at most 8 MiB, so the real
 * ceiling is whatever encodes into a frame with room for the rest of the message. At the 32 kbps
 * the recorder uses, five minutes is around 1.2 MB, so the limit is a guard, not a working size.
 */
object AudioPayload {
    /** The contract's own ceiling. */
    const val MAX_AUDIO_BYTES = 6L * 1024 * 1024

    /** What one frame may carry of base64, leaving room for the method, the ids and the braces. */
    const val MAX_ENCODED_BYTES = 8L * 1024 * 1024 - 4096

    /** Encoded in blocks so a long recording is never copied whole a second time. */
    private const val BLOCK_BYTES = 3 * 64 * 1024

    /** How many characters [size] bytes become once encoded, padding included. */
    fun encodedLength(size: Long): Long = 4 * ((size + 2) / 3)

    /** Whether a recording of [size] bytes may be sent as it is. */
    fun fits(size: Long): Boolean = size in 1..MAX_AUDIO_BYTES && encodedLength(size) <= MAX_ENCODED_BYTES

    /**
     * [audio] as base64, block by block.
     *
     * - Throws: [IllegalArgumentException] when the recording does not [fits]; the caller is
     *   expected to have refused it before reading the file.
     */
    fun encode(audio: ByteArray): String {
        require(fits(audio.size.toLong())) { "the recording is over what one frame carries" }
        val encoder = Base64.getEncoder()
        if (audio.size <= BLOCK_BYTES) return encoder.encodeToString(audio)
        val text = StringBuilder(encodedLength(audio.size.toLong()).toInt())
        var offset = 0
        while (offset < audio.size) {
            val end = minOf(offset + BLOCK_BYTES, audio.size)
            text.append(encoder.encodeToString(audio.copyOfRange(offset, end)))
            offset = end
        }
        return text.toString()
    }
}
