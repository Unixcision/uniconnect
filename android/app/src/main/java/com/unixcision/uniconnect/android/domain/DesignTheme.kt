package com.unixcision.uniconnect.android.domain

/**
 * The five design themes the app can be dressed in. A theme changes colour, layout and type at
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

    /** Calm: warm neutrals, generous air, soft cards with a large radius, regular sans type. */
    SERENO,

    /** Signal: near-white or ink ground, one strong accent, legible state colours, compact rows. */
    SENAL,

    /** Ink: editorial, serif headlines, hairlines instead of cards, high contrast, copper accent. */
    TINTA,

    /** Terminal: technical, monospaced identifiers, dense grid, muted phosphor green on graphite. */
    TERMINAL,

    /**
     * Aurora: noche polar. Un fondo azul casi negro, un acento menta de aurora boreal y, en
     * oscuro, tarjetas que no proyectan sombra sino **un halo de su propio color**, como luz que
     * sale del cristal. En claro es cielo glaciar con una sombra teñida de violeta. Etiquetas en
     * versalitas espaciadas, chips en píldora, cuadrícula de dos columnas.
     */
    AURORA;

    companion object {
        /** Reads a stored name, falling back to [SERENO] for anything unrecognised. */
        fun named(raw: String?): DesignTheme = entries.firstOrNull { it.name == raw } ?: SERENO
    }
}
