package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** How tall a list row is: [COMFORTABLE] leaves air around it, [COMPACT] packs more on screen. */
enum class RowDensity { COMFORTABLE, COMPACT }

/** How the boxes of a machine are laid out: one scrolling [RAIL] or a wrapping [GRID]. */
enum class WorkspaceLayout { RAIL, GRID }

/** What a card is drawn as: a filled [CARD] with an edge, or content between [HAIRLINE] rules. */
enum class CardStyle { CARD, HAIRLINE }

/** The layout decisions of one theme. */
@Immutable
data class UniLayout(
    val density: RowDensity,
    val workspacesAs: WorkspaceLayout,
    val cardsAs: CardStyle,
) {
    /** Vertical padding inside a list row, following [density]. */
    val rowPadding: Dp get() = if (density == RowDensity.COMPACT) 9.dp else 14.dp

    /** Padding inside a card that holds a machine or a message, following [density]. */
    val cardPadding: Dp get() = if (density == RowDensity.COMPACT) 13.dp else 18.dp
}
