package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
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
            DesignTheme.SERENO -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.serenoDark else UniPalettes.serenoLight,
                shapes = UniShapes(cardRadius = 24.dp, sheetRadius = 32.dp, chipRadius = 14.dp, buttonRadius = 18.dp),
                spacing = UniSpacing(page = 20.dp, gap = 14.dp, gapSmall = 8.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = false),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.RAIL, cardsAs = CardStyle.CARD),
            )
            DesignTheme.SENAL -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.senalDark else UniPalettes.senalLight,
                shapes = UniShapes(cardRadius = 12.dp, sheetRadius = 20.dp, chipRadius = 8.dp, buttonRadius = 10.dp),
                spacing = UniSpacing(page = 16.dp, gap = 8.dp, gapSmall = 4.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = true),
                layout = UniLayout(density = RowDensity.COMPACT, workspacesAs = WorkspaceLayout.RAIL, cardsAs = CardStyle.CARD),
            )
            DesignTheme.TINTA -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.tintaDark else UniPalettes.tintaLight,
                shapes = UniShapes(cardRadius = 4.dp, sheetRadius = 8.dp, chipRadius = 2.dp, buttonRadius = 4.dp),
                spacing = UniSpacing(page = 20.dp, gap = 10.dp, gapSmall = 6.dp),
                type = UniType(headlineFamily = FontFamily.Serif, identifierFamily = FontFamily.SansSerif, labelUppercase = true),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.GRID, cardsAs = CardStyle.HAIRLINE),
            )
            DesignTheme.TERMINAL -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.terminalDark else UniPalettes.terminalLight,
                shapes = UniShapes(cardRadius = 8.dp, sheetRadius = 12.dp, chipRadius = 6.dp, buttonRadius = 8.dp),
                spacing = UniSpacing(page = 14.dp, gap = 8.dp, gapSmall = 4.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.Monospace, labelUppercase = true),
                layout = UniLayout(density = RowDensity.COMPACT, workspacesAs = WorkspaceLayout.GRID, cardsAs = CardStyle.CARD),
            )
        }
    }
}
