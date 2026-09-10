package com.unixcision.uniconnect.android.domain

import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The arithmetic between the phone's codec and the model: bytes into samples, channels into one,
 * any rate into sixteen kilohertz.
 *
 * The codec itself cannot run in a JVM test, so the recording is synthesised here. Every mistake
 * this catches would reach the model as noise and come back as a wrong sentence, not as an error.
 */
class PcmSamplesTest {
    @Test
    fun signedSixteenBitLittleEndianBecomesSamplesBetweenMinusOneAndOne() {
        val pcm = pcm16(shortArrayOf(0, 16384, -16384, 32767, -32768))
        val samples = PcmSamples.fromPcm16(pcm)
        assertEquals(5, samples.size)
        assertEquals(0f, samples[0], 1e-6f)
        assertEquals(0.5f, samples[1], 1e-4f)
        assertEquals(-0.5f, samples[2], 1e-4f)
        assertTrue("full scale stays inside the range", samples[3] <= 1f && samples[3] > 0.99f)
        assertEquals(-1f, samples[4], 1e-6f)
    }

    @Test
    fun twoChannelsAreAveragedIntoOne() {
        // Left and right cancel out on the first frame and agree on the second.
        val pcm = pcm16(shortArrayOf(16384, -16384, 8192, 8192))
        val samples = PcmSamples.fromPcm16(pcm, pcm.size, channels = 2)
        assertEquals(2, samples.size)
        assertEquals(0f, samples[0], 1e-6f)
        assertEquals(0.25f, samples[1], 1e-4f)
    }

    @Test
    fun aTrailingHalfFrameIsDroppedInsteadOfReadAsSilence() {
        val pcm = pcm16(shortArrayOf(16384, 16384)) + byteArrayOf(7)
        val samples = PcmSamples.fromPcm16(pcm, pcm.size, channels = 2)
        assertEquals("one whole frame, not one and a half", 1, samples.size)
    }

    @Test
    fun floatOutputIsReadAsItComes() {
        val pcm = pcmFloat(floatArrayOf(0f, 0.25f, -0.75f))
        val samples = PcmSamples.fromPcmFloat(pcm)
        assertEquals(3, samples.size)
        assertEquals(0.25f, samples[1], 1e-6f)
        assertEquals(-0.75f, samples[2], 1e-6f)
    }

    @Test
    fun aRecordingAtAnotherRateComesOutAtSixteenKilohertz() {
        val tone = tone(hertz = 440.0, rate = 48_000, seconds = 0.25)
        val samples = PcmSamples.resample(tone, 48_000, PcmSamples.RATE)
        assertEquals(4_000, samples.size)
        assertEquals(0.25, PcmSamples.seconds(samples), 1e-9)
        // The tone survives: a quarter second of a 440 Hz sine crosses zero 220 times either way.
        assertTrue("the resampled tone still swings", samples.max() > 0.9f && samples.min() < -0.9f)
    }

    @Test
    fun aRecordingAlreadyAtSixteenKilohertzIsNotTouched() {
        val tone = tone(hertz = 200.0, rate = PcmSamples.RATE, seconds = 0.1)
        assertTrue("the same array, not a copy through the interpolator", tone === PcmSamples.resample(tone, PcmSamples.RATE, PcmSamples.RATE))
    }

    @Test
    fun aWholeSyntheticRecordingSurvivesBytesChannelsAndRateAtOnce() {
        val tone = tone(hertz = 300.0, rate = 44_100, seconds = 0.5)
        val stereo = ShortArray(tone.size * 2) { (tone[it / 2] * 32767).toInt().toShort() }
        val samples = PcmSamples.fromPcm16(pcm16(stereo), tone.size * 4, channels = 2, sampleRate = 44_100)
        assertEquals(8_000, samples.size)
        assertEquals(0.5, PcmSamples.seconds(samples), 1e-9)
        assertTrue("nothing was lost on the way", samples.any { abs(it) > 0.9f })
    }

    @Test
    fun nothingAtAllIsNoSamplesRatherThanAFailure() {
        assertEquals(0, PcmSamples.fromPcm16(ByteArray(0)).size)
        assertEquals(0, PcmSamples.fromPcm16(byteArrayOf(1)).size)
        assertEquals(0, PcmSamples.fromPcmFloat(ByteArray(3)).size)
    }

    private fun pcm16(samples: ShortArray): ByteArray {
        val bytes = ByteArray(samples.size * 2)
        samples.forEachIndexed { index, value ->
            bytes[index * 2] = (value.toInt() and 0xFF).toByte()
            bytes[index * 2 + 1] = ((value.toInt() shr 8) and 0xFF).toByte()
        }
        return bytes
    }

    private fun pcmFloat(samples: FloatArray): ByteArray {
        val bytes = ByteArray(samples.size * 4)
        samples.forEachIndexed { index, value ->
            val bits = value.toRawBits()
            for (shift in 0 until 4) bytes[index * 4 + shift] = ((bits shr (8 * shift)) and 0xFF).toByte()
        }
        return bytes
    }

    private fun tone(hertz: Double, rate: Int, seconds: Double): FloatArray {
        val frames = (rate * seconds).toInt()
        return FloatArray(frames) { sin(2 * Math.PI * hertz * it / rate).toFloat() }
    }
}
