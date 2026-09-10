package com.unixcision.uniconnect.android.data

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.unixcision.uniconnect.android.domain.AudioClip
import com.unixcision.uniconnect.android.domain.AudioDecodeFailed
import com.unixcision.uniconnect.android.domain.AudioDecoder
import com.unixcision.uniconnect.android.domain.PcmSamples
import java.io.ByteArrayOutputStream

/**
 * The platform's own codecs turning the recorded MPEG-4 file into samples.
 *
 * There is no ffmpeg on Android and no way to ask the recorder for raw PCM without giving up the
 * AAC file a machine expects, so the same recording is decoded here: [MediaExtractor] over the
 * bytes, [MediaCodec] for the track, and [PcmSamples] for the arithmetic that follows. Only the
 * platform part lives here; the mixing and the resampling are pure and tested on their own.
 */
class MediaCodecAudioDecoder : AudioDecoder {
    override fun decode(clip: AudioClip): FloatArray {
        val bytes = clip.read()
        if (bytes.isEmpty()) throw AudioDecodeFailed("the recording is empty")
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(ByteArrayMediaSource(bytes))
            val track = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw AudioDecodeFailed("the recording has no audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: throw AudioDecodeFailed("the track has no type")
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            return drain(extractor, decoder, format)
        } catch (failed: AudioDecodeFailed) {
            throw failed
        } catch (broken: Exception) {
            throw AudioDecodeFailed(broken.message ?: broken.javaClass.simpleName)
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            runCatching { extractor.release() }
        }
    }

    /** Feeds the codec until the track ends and collects everything it hands back. */
    private fun drain(extractor: MediaExtractor, codec: MediaCodec, input: MediaFormat): FloatArray {
        val pcm = ByteArrayOutputStream(INITIAL_BYTES)
        val info = MediaCodec.BufferInfo()
        var channels = input.optInt(MediaFormat.KEY_CHANNEL_COUNT, 1)
        var rate = input.optInt(MediaFormat.KEY_SAMPLE_RATE, PcmSamples.RATE)
        var encoding = AudioFormat.ENCODING_PCM_16BIT
        var fed = false
        var drained = false
        while (!drained) {
            if (!fed) {
                val index = codec.dequeueInputBuffer(TIMEOUT_US)
                if (index >= 0) {
                    val buffer = codec.getInputBuffer(index)
                    val read = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                    if (read < 0) {
                        codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        fed = true
                    } else {
                        codec.queueInputBuffer(index, 0, read, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            when (val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val output = codec.outputFormat
                    channels = output.optInt(MediaFormat.KEY_CHANNEL_COUNT, channels)
                    rate = output.optInt(MediaFormat.KEY_SAMPLE_RATE, rate)
                    encoding = output.optInt(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                }
                MediaCodec.INFO_TRY_AGAIN_LATER, MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                else -> if (index >= 0) {
                    val buffer = codec.getOutputBuffer(index)
                    if (buffer != null && info.size > 0) {
                        val chunk = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(chunk, 0, info.size)
                        if (pcm.size() + chunk.size <= MAX_PCM_BYTES) pcm.write(chunk)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) drained = true
                }
            }
        }
        val raw = pcm.toByteArray()
        if (raw.isEmpty()) throw AudioDecodeFailed("the codec produced no audio")
        return if (encoding == AudioFormat.ENCODING_PCM_FLOAT) PcmSamples.fromPcmFloat(raw, raw.size, channels, rate)
        else PcmSamples.fromPcm16(raw, raw.size, channels, rate)
    }

    /** A format value that may be absent; asking for a missing key throws instead of answering. */
    private fun MediaFormat.optInt(key: String, fallback: Int): Int =
        if (containsKey(key)) runCatching { getInteger(key) }.getOrDefault(fallback) else fallback

    private companion object {
        const val TIMEOUT_US = 10_000L

        /** A minute of 16 kHz mono PCM, so a short dictation never grows the buffer. */
        const val INITIAL_BYTES = 16_000 * 2 * 60

        /** Six minutes of it: the recorder stops at five, and this is the guard around that. */
        const val MAX_PCM_BYTES = 16_000 * 2 * 60 * 6
    }
}
