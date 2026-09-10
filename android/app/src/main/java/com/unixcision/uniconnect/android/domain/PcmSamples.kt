package com.unixcision.uniconnect.android.domain

/**
 * The arithmetic between a decoder's output and what Whisper reads: signed 16-bit samples become
 * floats, several channels become one, and any rate becomes 16 kHz.
 *
 * Pure on purpose. The platform's codec is impossible to run in a JVM test, the maths is not, and
 * this is where every mistake about channel order or rate would live.
 */
object PcmSamples {
    /** What Whisper expects, and what the recorder is already set to. */
    const val RATE = 16_000

    /** A signed 16-bit sample's full scale. */
    private const val FULL_SCALE = 32_768f

    /**
     * [length] bytes of little-endian signed 16-bit PCM as floats at [RATE].
     *
     * - Parameter channels: how many channels are interleaved in [pcm]; they are averaged into one.
     * - Parameter sampleRate: the rate [pcm] was decoded at.
     */
    fun fromPcm16(pcm: ByteArray, length: Int = pcm.size, channels: Int = 1, sampleRate: Int = RATE): FloatArray {
        val lanes = channels.coerceAtLeast(1)
        val frames = (length / 2) / lanes
        if (frames <= 0) return FloatArray(0)
        val mono = FloatArray(frames)
        var index = 0
        for (frame in 0 until frames) {
            var sum = 0f
            for (lane in 0 until lanes) {
                val low = pcm[index].toInt() and 0xFF
                val high = pcm[index + 1].toInt()
                sum += ((high shl 8) or low).toShort().toFloat() / FULL_SCALE
                index += 2
            }
            mono[frame] = sum / lanes
        }
        return resample(mono, sampleRate, RATE)
    }

    /**
     * [length] bytes of little-endian 32-bit float PCM as samples at [RATE]; some codecs answer in
     * floats and refusing them would mean refusing the recording on those phones.
     */
    fun fromPcmFloat(pcm: ByteArray, length: Int = pcm.size, channels: Int = 1, sampleRate: Int = RATE): FloatArray {
        val lanes = channels.coerceAtLeast(1)
        val frames = (length / 4) / lanes
        if (frames <= 0) return FloatArray(0)
        val mono = FloatArray(frames)
        var index = 0
        for (frame in 0 until frames) {
            var sum = 0f
            for (lane in 0 until lanes) {
                var bits = 0
                for (shift in 0 until 4) bits = bits or ((pcm[index + shift].toInt() and 0xFF) shl (8 * shift))
                sum += Float.fromBits(bits)
                index += 4
            }
            mono[frame] = sum / lanes
        }
        return resample(mono, sampleRate, RATE)
    }

    /**
     * [samples] taken at [from] hertz, at [to] hertz instead.
     *
     * Linear between neighbours. The recorder already captures at 16 kHz, so this only runs when a
     * codec answered at another rate, and speech resampled linearly is indistinguishable to a
     * model that reads a log-mel spectrogram.
     */
    fun resample(samples: FloatArray, from: Int, to: Int): FloatArray {
        if (from <= 0 || to <= 0 || from == to || samples.isEmpty()) return samples
        val frames = ((samples.size.toLong() * to) / from).toInt().coerceAtLeast(1)
        val out = FloatArray(frames)
        val step = from.toDouble() / to
        for (i in 0 until frames) {
            val at = i * step
            val left = at.toInt()
            if (left >= samples.size - 1) {
                out[i] = samples[samples.size - 1]
            } else {
                val fraction = (at - left).toFloat()
                out[i] = samples[left] * (1 - fraction) + samples[left + 1] * fraction
            }
        }
        return out
    }

    /** How many seconds [samples] hold at [RATE]. */
    fun seconds(samples: FloatArray): Double = samples.size.toDouble() / RATE
}
