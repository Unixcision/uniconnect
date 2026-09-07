package com.unixcision.uniconnect.android.domain

/**
 * How a desktop terminal is laid out on a phone screen.
 *
 * The desktop's own geometry is never changed to suit the phone, so the reader picks how to look
 * at it instead. This is a stored preference, which is why it lives here and not in the screen.
 */
enum class TerminalView {
    /** The whole desktop screen scaled down to the phone's width. */
    FIT,

    /** Readable size, with long desktop rows folded at the phone's width. */
    WRAP,

    /** Readable size at the desktop's true geometry, panned in both directions. */
    PAN;

    /** The next reading in the cycle, which is what the screen's single button offers. */
    val next: TerminalView get() = entries[(ordinal + 1) % entries.size]

    companion object {
        /** Reads a stored name, falling back to [PAN] for anything unrecognised. */
        fun named(raw: String?): TerminalView = entries.firstOrNull { it.name == raw } ?: PAN
    }
}
