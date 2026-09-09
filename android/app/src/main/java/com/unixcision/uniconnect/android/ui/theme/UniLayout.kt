package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** How tall a list row is: [COMFORTABLE] leaves air around it, [COMPACT] packs more on screen. */
enum class RowDensity { COMFORTABLE, COMPACT }

/** How the boxes of a machine are laid out: one scrolling [RAIL] of tiles or a wrapping [GRID] of cells. */
enum class WorkspaceLayout { RAIL, GRID }

/** What a block is drawn as: a flat [CARD] with an outline, or content between [HAIRLINE] rules. */
enum class CardStyle { CARD, HAIRLINE }

/**
 * The layout decisions of one theme.
 *
 * - [cardsAs] governs message blocks (empty state, not connected, notices).
 * - [rowsAs] governs list rows (machines, boxes in a grid, windows).
 * - [workspaceColumns] is how many cells a [WorkspaceLayout.GRID] puts in a row; one makes an index list.
 */
@Immutable
data class UniLayout(
    val density: RowDensity,
    val workspacesAs: WorkspaceLayout,
    val workspaceColumns: Int,
    val cardsAs: CardStyle,
    val rowsAs: CardStyle,
) {
    init {
        require(workspaceColumns >= 1) { "a grid needs at least one column, got $workspaceColumns" }
    }

    /** Vertical padding inside a list row, following [density]. */
    val rowPadding: Dp get() = if (density == RowDensity.COMPACT) 9.dp else 14.dp

    /** Padding inside a card that holds a machine or a message, following [density]. */
    val cardPadding: Dp get() = if (density == RowDensity.COMPACT) 13.dp else 18.dp

    /** Distance between consecutive rows: rules touch, cards breathe. */
    fun rowGap(spacing: UniSpacing): Dp = if (rowsAs == CardStyle.HAIRLINE) 0.dp else spacing.gap
}
