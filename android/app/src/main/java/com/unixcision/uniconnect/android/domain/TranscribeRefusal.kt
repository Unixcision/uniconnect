package com.unixcision.uniconnect.android.domain

/** The errors `mobile.audio.transcribe` may answer, as the contract names them. */
enum class TranscribeRefusal {
    /** Over 6 MiB or over five minutes of audio. */
    TOO_LARGE,

    /** The machine has no engine or no model; the phone dictates from now on. */
    UNSUPPORTED,

    /** UniConnect is locked on the machine. */
    LOCKED,

    /**
     * Another dictation is already running: the machine takes one per device and two in all,
     * because the engine eats every core it is given. It passes on its own, so it is a wait and
     * not a failure of the machine.
     */
    BUSY,

    /** The request was malformed, which is a bug on this side. */
    INVALID_PARAMS,

    /** The machine could not read or write the audio it was given. */
    IO_FAILED,

    /** A code this build does not know. */
    UNKNOWN;

    companion object {
        /** The host's error code as one of these; anything unknown stays [UNKNOWN]. */
        fun of(code: String?): TranscribeRefusal = when (code?.trim()?.lowercase()) {
            "too_large" -> TOO_LARGE
            "unsupported" -> UNSUPPORTED
            "locked" -> LOCKED
            "busy" -> BUSY
            "invalid_params" -> INVALID_PARAMS
            "io_failed" -> IO_FAILED
            else -> UNKNOWN
        }
    }
}
