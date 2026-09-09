package com.unixcision.uniconnect.android.domain

/** Where the reader wants dictated audio turned into text. */
enum class TranscriptionMode {
    /**
     * The window's machine when it can, any other connected machine that can, and the phone when
     * none can. The shipped default, and the one that lets a laptop transcribe for a terminal that
     * lives on a small server.
     */
    AUTO,

    /** Always the phone's own recogniser, however good the machines are. */
    PHONE,

    /** Always the machine of the window; when it cannot, the phone is used and the reader is told. */
    HOST,

    /** Always one machine the reader picked, whichever window is open. */
    MACHINE;

    companion object {
        /** Reads a stored name, falling back to [AUTO] for anything unrecognised. */
        fun named(raw: String?): TranscriptionMode = entries.firstOrNull { it.name == raw } ?: AUTO
    }
}
