package com.unixcision.uniconnect.android.domain

import java.util.Base64

/**
 * How a recording travels inside `mobile.audio.transcribe`: base64 in one JSON frame.
 *
 * Base64 grows what it carries by a third, so the ceiling is not the frame's own size. The
 * contract refuses over 3 MiB of audio, which encodes into about 4 MiB and leaves half a frame
 * free for everything around it; at the 32 kbps the recorder uses, five minutes is around
 * 1.2 MB, so the limit is a guard and not a working size.
 *
 * A recording is measured before it is read: nothing over the ceiling is ever sent, so the phone
 * says what happened instead of breaking a frame the machine could not have answered.
 */
object AudioPayload {
    /** The contract's own ceiling: 3 MiB of audio, or five minutes, whichever comes first. */
    const val MAX_AUDIO_BYTES = 3L * 1024 * 1024

    /** The transport's frame ceiling, which is the 8 MiB `FramedRpcClient` enforces. */
    const val MAX_FRAME_BYTES = 8L * 1024 * 1024

    /** Room for the method, the request id, the keys and the braces around the audio. */
    const val ENVELOPE_BYTES = 1024L

    /** Encoded in blocks so a long recording is never copied whole a second time. */
    private const val BLOCK_BYTES = 3 * 64 * 1024

    /** How many characters [size] bytes become once encoded, padding included. */
    fun encodedLength(size: Long): Long = 4 * ((size + 2) / 3)

    /** Whether a recording of [size] bytes may be sent as it is. */
    fun fits(size: Long): Boolean =
        size in 1..MAX_AUDIO_BYTES && requestFits(encodedLength(size), fieldBytes = 0)

    /**
     * Whether the whole request fits one frame: the audio once encoded, plus [fieldBytes] for the
     * ids and the language that travel beside it, plus the envelope around them.
     */
    fun requestFits(encodedLength: Long, fieldBytes: Long): Boolean =
        encodedLength + fieldBytes + ENVELOPE_BYTES <= MAX_FRAME_BYTES

    /**
     * [audio] as base64, block by block.
     *
     * - Throws: [IllegalArgumentException] when the recording does not [fits]; the caller is
     *   expected to have refused it before reading the file.
     */
    fun encode(audio: ByteArray): String {
        require(fits(audio.size.toLong())) { "the recording is over what the contract takes" }
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
