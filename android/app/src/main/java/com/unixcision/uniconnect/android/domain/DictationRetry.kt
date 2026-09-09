package com.unixcision.uniconnect.android.domain

/** What the reader can do about a dictation that ended badly. */
enum class DictationRetry {
    /** Nothing worth offering; the recording is gone. */
    NONE,

    /** The recording is kept and may be sent to a machine once more. */
    RESEND,

    /** The recording cannot be used; a new, shorter one is the way out. */
    RERECORD,

    /**
     * No machine is going to take this recording, so the next one is spoken to the phone itself.
     * The phone's recogniser needs a live microphone and can do nothing with a file, which is why
     * this starts a new dictation instead of sending the old one anywhere.
     */
    DICTATE_ON_PHONE,
}
