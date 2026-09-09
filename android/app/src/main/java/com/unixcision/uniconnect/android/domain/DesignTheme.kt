package com.unixcision.uniconnect.android.domain

/**
 * The four design themes the app can be dressed in. A theme changes colour, layout and type at
 * once; whether it is shown light or dark is a separate choice, [ColorMode].
 *
 * The names are stable identifiers stored on the phone; the visible names live in resources.
 */
enum class DesignTheme {
    /** Calm: warm neutrals, generous air, soft cards with a large radius, regular sans type. */
    SERENO,

    /** Signal: near-white or ink ground, one strong accent, legible state colours, compact rows. */
    SENAL,

    /** Ink: editorial, serif headlines, hairlines instead of cards, high contrast, copper accent. */
    TINTA,

    /** Terminal: technical, monospaced identifiers, dense grid, muted phosphor green on graphite. */
    TERMINAL;

    companion object {
        /** Reads a stored name, falling back to [SERENO] for anything unrecognised. */
        fun named(raw: String?): DesignTheme = entries.firstOrNull { it.name == raw } ?: SERENO
    }
}
