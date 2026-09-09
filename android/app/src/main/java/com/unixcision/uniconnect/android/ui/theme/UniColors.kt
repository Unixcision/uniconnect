package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * The colour tokens of one theme in one mode. Screens read these, never a fixed palette.
 *
 * - [background] is the page, flat; [surface] sits on it (cards, sheets); [surfaceRaised] sits on
 *   that (menus, dialogs, key caps, containers inside a sheet).
 * - [outline] is a translucent rule for borders and hairlines, so it reads on any of the three.
 * - [accent] is the one strong colour, with [onAccent] for what is drawn on top of it and
 *   [accentSoft] as the same accent at container strength: a tint behind text, never text.
 * - [success], [warning] and [danger] are the state colours.
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
    val tones: List<Color>,
) {
    /** The outline fading to half strength, for a frame edge that should not compete with its content. */
    val outlineFade: Brush get() = Brush.verticalGradient(listOf(outline, outline.copy(alpha = outline.alpha * .5f)))

    init {
        require(tones.size == TONE_COUNT) { "every theme carries $TONE_COUNT tones, got ${tones.size}" }
    }

    companion object {
        /** How many identity tones a palette carries; fixed so a name maps to the same slot everywhere. */
        const val TONE_COUNT = 8
    }
}
