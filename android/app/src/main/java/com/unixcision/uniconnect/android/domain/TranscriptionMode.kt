package com.unixcision.uniconnect.android.domain

/** Where the reader wants dictated audio turned into text. */
enum class TranscriptionMode {
    /** The machine when it announces `transcribe.v1`, the phone otherwise. The shipped default. */
    AUTO,

    /** Always the phone's own recogniser, however good the machine is. */
    PHONE,

    /** Always the machine; when it cannot, the phone is used and the reader is told every time. */
    HOST;

    companion object {
        /** Reads a stored name, falling back to [AUTO] for anything unrecognised. */
        fun named(raw: String?): TranscriptionMode = entries.firstOrNull { it.name == raw } ?: AUTO
    }
}
