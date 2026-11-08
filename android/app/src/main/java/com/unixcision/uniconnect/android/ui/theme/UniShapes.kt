package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Immutable
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Corner radii of one theme, kept as measurements so they can be compared in tests, with the
 * shapes built from them for the screens: continuous corners, as Apple draws them, for every
 * surface the app draws itself, and plain rounded corners of the same radii for the Material
 * components that only take those.
 */
@Immutable
data class UniShapes(
    val cardRadius: Dp,
    val sheetRadius: Dp,
    val chipRadius: Dp,
    val buttonRadius: Dp,
    /**
     * Text fields, which follow the buttons unless a theme rounds its buttons into pills: a
     * floating label cannot sit in the notch of a corner that wide.
     */
    val fieldRadius: Dp = buttonRadius,
) {
    /** Cards, rows and the terminal frame. */
    val card: Shape get() = ContinuousRoundedShape(cardRadius)

    /** Bottom sheets and dialogs. */
    val sheet: Shape get() = ContinuousRoundedShape(sheetRadius)

    /** Badges, key caps and small tiles. */
    val chip: Shape get() = ContinuousRoundedShape(chipRadius)

    /** Buttons. */
    val button: Shape get() = ContinuousRoundedShape(buttonRadius)

    /** Text fields. */
    val field: Shape get() = ContinuousRoundedShape(fieldRadius)

    /** The same radii as plain rounded corners, for Material's own components. */
    val materialChip: CornerBasedShape get() = RoundedCornerShape(chipRadius)
    val materialButton: CornerBasedShape get() = RoundedCornerShape(buttonRadius)
    val materialCard: CornerBasedShape get() = RoundedCornerShape(cardRadius)
    val materialSheet: CornerBasedShape get() = RoundedCornerShape(sheetRadius)

    companion object {
        /**
         * The one radius scale of the app, Apple's: continuous corners that round a card without
         * turning it into a pill, the same in every theme so everything reads as one product.
         */
        val apple = UniShapes(cardRadius = 16.dp, sheetRadius = 24.dp, chipRadius = 10.dp, buttonRadius = 12.dp, fieldRadius = 12.dp)
    }
}
