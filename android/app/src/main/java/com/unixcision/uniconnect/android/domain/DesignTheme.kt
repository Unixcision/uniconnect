package com.unixcision.uniconnect.android.domain

/**
 * The four design themes the app can be dressed in. A theme changes colour, layout and type at
 * once; whether it is shown light or dark is a separate choice, [ColorMode].
 *
 * The names are stable identifiers stored on the phone; the visible names live in resources.
 */
enum class DesignTheme {
    /**
     * Snow: the quietest of them. An off-white page with white surfaces floating on it under a
     * soft shadow, very large radii, wide margins and one graphite indigo as the only colour.
     */
    NIEVE,

    /**
     * Obsidian: ink black and one electric violet, compact rows between hairlines, small radii
     * and tracked capitals; the precision of the tools engineers live in.
     */
    OBSIDIANA,

    /**
     * Sand: warm and editorial. A sand page, terracotta, serif headlines, roomy cards on a warm
     * shadow and pill chips; roasted coffee and an ember in the dark.
     */
    ARENA,

    /**
     * Lime: bento. Chunky rounded tiles in two columns on a deep green-black, one acid lime and
     * monospaced names and numbers; a pale sage with an olive accent in the light.
     */
    LIMA;

    companion object {
        /**
         * Reads a stored name, falling back to [NIEVE] for anything unrecognised, including the
         * themes removed on 8-11-2026 (Sereno, Señal, Tinta, Terminal and Aurora).
         */
        fun named(raw: String?): DesignTheme = entries.firstOrNull { it.name == raw } ?: NIEVE
    }
}
