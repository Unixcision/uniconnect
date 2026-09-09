package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.domain.DesignTheme

/** Everything a screen needs to know about how it is dressed: one theme in one mode. */
@Immutable
data class UniTokens(
    val theme: DesignTheme,
    val colors: UniColors,
    val shapes: UniShapes,
    val spacing: UniSpacing,
    val type: UniType,
    val layout: UniLayout,
) {
    companion object {
        /**
         * The tokens of [theme] shown [dark] or light. Pure: the same pair always gives the same
         * tokens, which is what lets a test walk all eight combinations.
         */
        fun tokensFor(theme: DesignTheme, dark: Boolean): UniTokens = when (theme) {
            // Calm: soft cards, a rail of rounded tiles, roomy rows, labels in sentence case.
            DesignTheme.SERENO -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.serenoDark else UniPalettes.serenoLight,
                shapes = UniShapes(cardRadius = 24.dp, sheetRadius = 32.dp, chipRadius = 14.dp, buttonRadius = 18.dp),
                spacing = UniSpacing(page = 20.dp, gap = 14.dp, gapSmall = 8.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = false, labelLetterSpacing = 0.3.sp),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.RAIL, workspaceColumns = 1, cardsAs = CardStyle.CARD, rowsAs = CardStyle.CARD),
            )
            // Signal: compact rows between hairlines, boxes in two columns, tracked capitals.
            DesignTheme.SENAL -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.senalDark else UniPalettes.senalLight,
                shapes = UniShapes(cardRadius = 12.dp, sheetRadius = 20.dp, chipRadius = 8.dp, buttonRadius = 10.dp),
                spacing = UniSpacing(page = 16.dp, gap = 8.dp, gapSmall = 4.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = true, labelLetterSpacing = 1.sp),
                layout = UniLayout(density = RowDensity.COMPACT, workspacesAs = WorkspaceLayout.GRID, workspaceColumns = 2, cardsAs = CardStyle.CARD, rowsAs = CardStyle.HAIRLINE),
            )
            // Ink: serif headlines, wide margins, everything between rules, boxes as an index list.
            DesignTheme.TINTA -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.tintaDark else UniPalettes.tintaLight,
                shapes = UniShapes(cardRadius = 4.dp, sheetRadius = 8.dp, chipRadius = 2.dp, buttonRadius = 4.dp),
                spacing = UniSpacing(page = 24.dp, gap = 12.dp, gapSmall = 6.dp),
                type = UniType(headlineFamily = FontFamily.Serif, identifierFamily = FontFamily.SansSerif, labelUppercase = true, labelLetterSpacing = 1.4.sp),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.GRID, workspaceColumns = 1, cardsAs = CardStyle.HAIRLINE, rowsAs = CardStyle.HAIRLINE),
            )
            // Terminal: monospaced identifiers, outlined cells in a dense three-column grid.
            DesignTheme.TERMINAL -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.terminalDark else UniPalettes.terminalLight,
                shapes = UniShapes(cardRadius = 8.dp, sheetRadius = 12.dp, chipRadius = 6.dp, buttonRadius = 8.dp),
                spacing = UniSpacing(page = 14.dp, gap = 8.dp, gapSmall = 4.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.Monospace, labelUppercase = true, labelLetterSpacing = 0.8.sp),
                layout = UniLayout(density = RowDensity.COMPACT, workspacesAs = WorkspaceLayout.GRID, workspaceColumns = 3, cardsAs = CardStyle.CARD, rowsAs = CardStyle.CARD),
            )
        }
    }
}
