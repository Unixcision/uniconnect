package com.unixcision.uniconnect.android.domain

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** What travels in `mobile.audio.transcribe`: the encoding block by block and the size ceiling. */
class AudioPayloadTest {
    @Test
    fun blockByBlockEncodingIsTheSameAsEncodingItWhole() {
        listOf(1, 2, 3, 1024, 3 * 64 * 1024, 3 * 64 * 1024 + 1, 700_000).forEach { size ->
            val audio = ByteArray(size) { (it * 31 % 251).toByte() }
            assertEquals("$size bytes", Base64.getEncoder().encodeToString(audio), AudioPayload.encode(audio))
        }
    }

    @Test
    fun whatIsEncodedComesBackAsItWent() {
        val audio = ByteArray(500_000) { (it % 256).toByte() }
        assertTrue(audio.contentEquals(Base64.getDecoder().decode(AudioPayload.encode(audio))))
    }

    @Test
    fun theEncodedLengthIsTheOneBase64Produces() {
        listOf(0L, 1L, 2L, 3L, 4L, 999L, 1_048_576L).forEach { size ->
            val expected = Base64.getEncoder().encodeToString(ByteArray(size.toInt())).length.toLong()
            assertEquals("$size bytes", expected, AudioPayload.encodedLength(size))
        }
    }

    @Test
    fun nothingOverSixMebibytesFitsAndNeitherDoesAnEmptyRecording() {
        assertFalse("the contract refuses over 6 MiB", AudioPayload.fits(AudioPayload.MAX_AUDIO_BYTES + 1))
        assertFalse("nothing was recorded", AudioPayload.fits(0))
        assertFalse(AudioPayload.fits(-1))
        // Five minutes at 32 kbps is around 1.2 MB, so the working sizes are far below the ceiling.
        assertTrue(AudioPayload.fits(1_200_000))
        assertTrue(AudioPayload.fits(1))
    }

    @Test
    fun theRealCeilingIsWhatOneFrameCarriesEncoded() {
        val largest = (1..AudioPayload.MAX_AUDIO_BYTES).last { AudioPayload.fits(it) }
        assertTrue("a fitting recording encodes inside a frame", AudioPayload.encodedLength(largest) <= AudioPayload.MAX_ENCODED_BYTES)
        assertFalse("one byte more does not", AudioPayload.fits(largest + 1))
        assertTrue("and it is under the contract's own ceiling", largest <= AudioPayload.MAX_AUDIO_BYTES)
    }

    @Test
    fun encodingSomethingThatDoesNotFitIsRefusedInsteadOfSent() {
        assertThrows(IllegalArgumentException::class.java) { AudioPayload.encode(ByteArray(0)) }
    }
}
