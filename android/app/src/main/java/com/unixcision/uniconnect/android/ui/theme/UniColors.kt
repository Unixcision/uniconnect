package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color

/**
 * The colour tokens of one theme in one mode. Screens read these, never a fixed palette.
 *
 * - [background] is the page; [surface] sits on it (cards, sheets); [surfaceRaised] sits on that
 *   (menus, dialogs, key caps, containers inside a sheet).
 * - [accent] is the one strong colour, with [onAccent] for what is drawn on top of it and
 *   [accentSoft] as the quieter second accent (labels, secondary badges).
 * - [success], [warning] and [danger] are the state colours.
 * - [glassTop] and [glassBottom] are the translucent edge of a glass card.
 * - [tones] are the eight deterministic identity colours for monograms; every theme has eight,
 *   so a box keeps its slot when the theme changes.
 */
@Immutable
data class UniColors(
    val isDark: Boolean,
    val background: Color,
    val surface: Color,
    val surfaceRaised: Color,
    val outline: Color,
    val text: Color,
    val muted: Color,
    val accent: Color,
    val onAccent: Color,
    val accentSoft: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
    val glassTop: Color,
    val glassBottom: Color,
    val tones: List<Color>,
) {
    init {
        require(tones.size == TONE_COUNT) { "every theme carries $TONE_COUNT tones, got ${tones.size}" }
    }

    companion object {
        /** How many identity tones a palette carries; fixed so a name maps to the same slot everywhere. */
        const val TONE_COUNT = 8
    }
}
