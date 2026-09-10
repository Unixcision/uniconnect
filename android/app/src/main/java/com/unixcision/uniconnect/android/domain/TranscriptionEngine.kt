package com.unixcision.uniconnect.android.domain

/** Which of the three dictations is driving. */
enum class TranscriptionEngine {
    /** The phone's own speech recogniser, the one Android ships with. */
    PHONE,

    /** A machine transcribes the recording over `transcribe.v1`. */
    HOST,

    /** Whisper running on this phone, with no connection at all. */
    LOCAL,
}
