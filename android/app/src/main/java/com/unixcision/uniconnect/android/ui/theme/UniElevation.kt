package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * How a surface is told apart from the ground it sits on, in one theme and one mode.
 *
 * A flat theme separates with a rule: a [hairline] one pixel wide and no shadow at all, which is
 * what every theme did before this token existed. A floating theme separates with light, in the
 * two layers a real object casts: [ambient] is the wide, very faint halo that says the surface is
 * off the page, and [key] the short, darker one just beneath it that says how far off. Both are
 * radii in the sense `Modifier.shadow` uses, with their colour already at the alpha it is drawn
 * with.
 *
 * A shadow does not read on a dark ground, so a floating theme lifts its surfaces with
 * [surfaceLift] there instead: white laid over the fill at a small alpha, which is the same trick
 * the desktop uses when it cannot cast light.
 */
@Immutable
data class UniElevation(
    val ambient: Dp,
    val ambientColor: Color,
    val key: Dp,
    val keyColor: Color,
    val surfaceLift: Float,
    val hairline: Dp,
) {
    /** Whether this reading separates a surface with light rather than with a rule. */
    val floats: Boolean get() = ambient > 0.dp || key > 0.dp || surfaceLift > 0f

    init {
        require(surfaceLift in 0f..1f) { "a lift is an alpha, got $surfaceLift" }
        require(ambient.value >= 0f && key.value >= 0f && hairline.value >= 0f) { "a radius cannot be negative" }
    }

    companion object {
        /** No shadow and no lift: the one pixel edge the flat themes have always drawn. */
        val flat = UniElevation(
            ambient = 0.dp, ambientColor = Color.Transparent,
            key = 0.dp, keyColor = Color.Transparent,
            surfaceLift = 0f, hairline = 1.dp,
        )
    }
}
