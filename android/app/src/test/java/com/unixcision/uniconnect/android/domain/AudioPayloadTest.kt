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
    fun theCeilingIsThreeMebibytesOfAudioAndNothingEmpty() {
        assertEquals(3L * 1024 * 1024, AudioPayload.MAX_AUDIO_BYTES)
        assertTrue("the last byte the contract takes", AudioPayload.fits(AudioPayload.MAX_AUDIO_BYTES))
        assertFalse("one byte more is refused here, not by the host", AudioPayload.fits(AudioPayload.MAX_AUDIO_BYTES + 1))
        assertFalse("nothing was recorded", AudioPayload.fits(0))
        assertFalse(AudioPayload.fits(-1))
        // Five minutes at 32 kbps is around 1.2 MB, so the working sizes are far below the ceiling.
        assertTrue(AudioPayload.fits(1_200_000))
        assertTrue(AudioPayload.fits(1))
    }

    @Test
    fun theWholeCeilingEncodesWithHalfAFrameToSpare() {
        val encoded = AudioPayload.encodedLength(AudioPayload.MAX_AUDIO_BYTES)
        assertEquals("base64 grows it by a third", 4L * 1024 * 1024, encoded)
        assertTrue("the largest request the phone can build fits one frame", AudioPayload.requestFits(encoded, fieldBytes = 4096))
        assertEquals("which is exactly half a frame", AudioPayload.MAX_FRAME_BYTES / 2, encoded)
        assertTrue("so half the frame is free for everything else", AudioPayload.MAX_FRAME_BYTES - encoded >= 4L * 1024 * 1024)
    }

    @Test
    fun aRequestThatWouldBreakTheFrameIsRefusedBeforeItIsBuilt() {
        val frame = AudioPayload.MAX_FRAME_BYTES
        assertTrue(AudioPayload.requestFits(frame - AudioPayload.ENVELOPE_BYTES, fieldBytes = 0))
        assertFalse(AudioPayload.requestFits(frame - AudioPayload.ENVELOPE_BYTES + 1, fieldBytes = 0))
        assertFalse("the ids and the language count too", AudioPayload.requestFits(frame - AudioPayload.ENVELOPE_BYTES - 10, fieldBytes = 11))
        // The old 6 MiB ceiling encoded into exactly one frame, leaving no room for the message.
        assertFalse(AudioPayload.requestFits(AudioPayload.encodedLength(6L * 1024 * 1024), fieldBytes = 0))
    }

    @Test
    fun encodingSomethingThatDoesNotFitIsRefusedInsteadOfSent() {
        assertThrows(IllegalArgumentException::class.java) { AudioPayload.encode(ByteArray(0)) }
        assertThrows(IllegalArgumentException::class.java) { AudioPayload.encode(ByteArray((AudioPayload.MAX_AUDIO_BYTES + 1).toInt())) }
    }
}
