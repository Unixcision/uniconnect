package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.Dp

/**
 * The distances of one theme: [page] is the margin from the screen edge, [gap] separates items
 * of a list or a section, [gapSmall] separates things inside one row.
 */
@Immutable
data class UniSpacing(
    val page: Dp,
    val gap: Dp,
    val gapSmall: Dp,
)
