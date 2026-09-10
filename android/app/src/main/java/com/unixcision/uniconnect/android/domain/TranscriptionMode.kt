package com.unixcision.uniconnect.android.domain

/** Where the reader wants dictated audio turned into text. */
enum class TranscriptionMode {
    /**
     * The best that is there, in this order: the machine of the window, any other connected
     * machine that can, Whisper on this phone when a model is downloaded, and the phone's own
     * recogniser when nothing else answers. The shipped default.
     */
    AUTO,

    /** Always one machine the reader picked, whichever window is open. */
    MACHINE,

    /** Always Whisper on this phone. Needs a downloaded model; without one the automatic rule runs. */
    LOCAL,

    /** Always the phone's system recogniser, the one that understands worst. */
    PHONE;

    companion object {
        /**
         * Reads a stored name, falling back to [AUTO] for anything unrecognised.
         *
         * `HOST` was "always the machine of the window" and is no longer offered: [AUTO] already
         * prefers that machine and, unlike `HOST`, has somewhere to go when it cannot. A store
         * written by an older build reads as [AUTO].
         */
        fun named(raw: String?): TranscriptionMode = entries.firstOrNull { it.name == raw } ?: AUTO
    }
}
