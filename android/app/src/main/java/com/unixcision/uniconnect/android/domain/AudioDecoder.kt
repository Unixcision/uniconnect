package com.unixcision.uniconnect.android.domain

/**
 * Turns a recording into the samples Whisper reads: 16 kHz, one channel, floats from -1 to 1.
 *
 * The phone records AAC in an MPEG-4 container because that is what travels to a machine, and
 * nothing on Android decodes it outside the platform's own codecs, so the whole of it lives
 * behind this seam and the arithmetic that follows lives in [PcmSamples].
 */
interface AudioDecoder {
    /**
     * - Returns: the whole recording as samples.
     * - Throws: [AudioDecodeFailed] when the file holds no audio track or the codec refused it.
     */
    fun decode(clip: AudioClip): FloatArray
}

/** A recording that could not be turned into samples. */
class AudioDecodeFailed(message: String) : Exception(message)
