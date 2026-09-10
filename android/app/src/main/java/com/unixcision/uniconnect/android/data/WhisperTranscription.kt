package com.unixcision.uniconnect.android.data

import android.os.SystemClock
import android.util.Log
import com.unixcision.uniconnect.android.domain.LocalTranscription
import com.unixcision.uniconnect.android.domain.LocalTranscriptionFailed
import com.unixcision.uniconnect.android.domain.PcmSamples
import com.unixcision.uniconnect.android.domain.Transcript
import com.unixcision.uniconnect.android.domain.TranscriptionProgress

/**
 * [LocalTranscription] over the vendored whisper.cpp.
 *
 * One context per recording: the model is opened, read and released around a single call, so a
 * dictation never leaves half a gigabyte of weights resident between two sentences. Opening a
 * quantised base model costs well under a second and the recording that follows costs far more,
 * which is the trade this makes on purpose.
 *
 * The call itself is blocking and belongs on a background dispatcher; the caller is
 * [com.unixcision.uniconnect.android.domain.LocalDictation], which runs it on `Dispatchers.Default`
 * and cancels it through [progress].
 */
class WhisperTranscription(private val threads: Int = defaultThreads()) : LocalTranscription {
    override val available: Boolean get() = WhisperNative.loaded

    override suspend fun transcribe(samples: FloatArray, modelPath: String, language: String?, progress: TranscriptionProgress?): Transcript? {
        if (!WhisperNative.loaded) throw LocalTranscriptionFailed("the engine is not available on this phone")
        val handle = WhisperNative.openModel(modelPath)
        if (handle == 0L) throw LocalTranscriptionFailed("the model could not be opened")
        return try {
            val started = SystemClock.elapsedRealtime()
            val text = WhisperNative.transcribe(handle, samples, threads, language, progress) ?: return null
            val took = SystemClock.elapsedRealtime() - started
            val seconds = PcmSamples.seconds(samples)
            // Measured every time, because how long a phone takes is the whole question about
            // this engine and the answer depends on the model, the phone and how hot it is.
            Log.i(TAG, "whisper on device: %.1f s of audio in %d ms with %d threads".format(seconds, took, threads))
            Transcript(text = text.trim(), engine = ENGINE, seconds = seconds, tookMillis = took)
        } finally {
            WhisperNative.closeModel(handle)
        }
    }

    /** What whisper.cpp reports about the instruction sets it found; empty when it did not load. */
    fun systemInfo(): String = if (WhisperNative.loaded) runCatching { WhisperNative.systemInfo() }.getOrDefault("") else ""

    private companion object {
        const val TAG = "UniConnectWhisper"
        const val ENGINE = "whisper.cpp"

        /**
         * Half the cores, between two and six.
         *
         * A phone's little cores are slower than the memory bandwidth the model already saturates,
         * so asking for every core makes it hotter without making it faster; a Tensor G3 with nine
         * cores lands on four, which is what the big cluster holds.
         */
        fun defaultThreads(): Int = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(2, 6)
    }
}
