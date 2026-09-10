package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.TranscriptionProgress
import java.io.File

/**
 * The vendored whisper.cpp, as four calls.
 *
 * The library is built for `arm64-v8a` with ARMv8.2 half-precision and dot-product kernels,
 * because a quantised model is unusable on a phone without them. That is not a baseline every
 * arm64 CPU has, so [loadable] asks the kernel what this one advertises before the library is
 * loaded at all: a phone without them transcribes somewhere else rather than dying on an illegal
 * instruction the moment the first matrix is multiplied.
 */
internal object WhisperNative {
    /** Opens the model file; returns 0 when it could not be read. */
    external fun openModel(modelPath: String): Long

    /** Releases the context; calling it with 0 is harmless. */
    external fun closeModel(handle: Long)

    /**
     * Reads [samples] (16 kHz mono) with the open model and returns the text, or null when the run
     * failed or [progress] asked for it to stop.
     */
    external fun transcribe(handle: Long, samples: FloatArray, threads: Int, language: String?, progress: TranscriptionProgress?): String?

    /** What whisper.cpp believes it is running on, for the report. */
    external fun systemInfo(): String

    /** Whether the library was loaded; false on a CPU without the kernels it is built for. */
    val loaded: Boolean by lazy {
        if (!loadable()) false
        else runCatching { System.loadLibrary("uniwhisper") }.isSuccess
    }

    /**
     * Whether this CPU advertises the half-precision and dot-product extensions the library needs.
     *
     * `/proc/cpuinfo` names them `asimdhp` and `asimddp` on arm64. An unreadable file is read as
     * "no": refusing to run is recoverable and a SIGILL is not.
     */
    private fun loadable(): Boolean {
        val features = runCatching { File("/proc/cpuinfo").readText() }.getOrNull() ?: return false
        return features.contains("asimdhp") && features.contains("asimddp")
    }
}
