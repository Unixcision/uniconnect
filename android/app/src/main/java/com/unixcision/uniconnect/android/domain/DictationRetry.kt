package com.unixcision.uniconnect.android.domain

/** What the reader can do about a dictation that ended badly. */
enum class DictationRetry {
    /** Nothing worth offering; the recording is gone. */
    NONE,

    /** The recording is kept and may be sent to the machine once more. */
    RESEND,

    /** The recording cannot be used; a new, shorter one is the way out. */
    RERECORD,
}
