package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import com.unixcision.uniconnect.android.domain.AudioClip
import com.unixcision.uniconnect.android.domain.VoiceRecorder
import java.io.File
import kotlin.math.sqrt

/**
 * The phone's own microphone into an MPEG-4 file with AAC audio, 16 kHz mono at 32 kbps: the shape
 * Whisper reads without resampling and small enough that a whole minute is around 240 KB.
 *
 * The file lives in the cache directory and belongs to the clip that comes out of [stop]; whoever
 * takes it is the one that deletes it. A recording interrupted by [discard] leaves nothing behind.
 */
class MediaRecorderVoice(private val context: Context) : VoiceRecorder {
    private var recorder: MediaRecorder? = null
    private var file: File? = null

    override val available: Boolean
        get() = context.packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE)

    override fun start(): Boolean {
        discard()
        val destination = File(context.cacheDir, "dictado-${System.currentTimeMillis()}.m4a")
        val created = runCatching {
            @Suppress("DEPRECATION")
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else MediaRecorder()
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioChannels(CHANNELS)
            recorder.setAudioSamplingRate(SAMPLE_RATE)
            recorder.setAudioEncodingBitRate(BIT_RATE)
            recorder.setOutputFile(destination.absolutePath)
            recorder.prepare()
            recorder.start()
            recorder
        }.getOrElse {
            runCatching { destination.delete() }
            return false
        }
        recorder = created
        file = destination
        return true
    }

    override fun level(): Float {
        // maxAmplitude is the peak since the previous call; the square root gives a meter that
        // moves with the voice instead of sitting near zero.
        val peak = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
        return sqrt((peak.coerceIn(0, PEAK).toFloat() / PEAK)).coerceIn(0f, 1f)
    }

    override fun stop(): AudioClip? {
        val running = recorder
        val written = file
        recorder = null
        file = null
        if (running == null || written == null) return null
        val kept = runCatching { running.stop() }.isSuccess
        runCatching { running.release() }
        if (!kept || !written.exists() || written.length() <= 0) {
            runCatching { written.delete() }
            return null
        }
        return CachedAudioClip(written)
    }

    override fun discard() {
        val running = recorder
        val written = file
        recorder = null
        file = null
        running?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        written?.let { runCatching { it.delete() } }
    }

    private companion object {
        const val SAMPLE_RATE = 16_000
        const val CHANNELS = 1
        const val BIT_RATE = 32_000

        /** A 16-bit sample's peak, which is what maxAmplitude reports against. */
        const val PEAK = 32_767
    }
}
