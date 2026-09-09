package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Immutable
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.ui.unit.Dp

/**
 * Corner radii of one theme, kept as measurements so they can be compared in tests, with the
 * shapes built from them for the screens.
 */
@Immutable
data class UniShapes(
    val cardRadius: Dp,
    val sheetRadius: Dp,
    val chipRadius: Dp,
    val buttonRadius: Dp,
) {
    /** Cards, rows and the terminal frame. */
    val card: CornerBasedShape get() = RoundedCornerShape(cardRadius)

    /** Bottom sheets and dialogs. */
    val sheet: CornerBasedShape get() = RoundedCornerShape(sheetRadius)

    /** Badges, key caps and small tiles. */
    val chip: CornerBasedShape get() = RoundedCornerShape(chipRadius)

    /** Buttons and text fields. */
    val button: CornerBasedShape get() = RoundedCornerShape(buttonRadius)
}
