package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
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
    val elevation: UniElevation,
) {
    companion object {
        /**
         * The tokens of [theme] shown [dark] or light. Pure: the same pair always gives the same
         * tokens, which is what lets a test walk all eight combinations.
         */
        fun tokensFor(theme: DesignTheme, dark: Boolean): UniTokens = when (theme) {
            // Snow: white surfaces floating over an off-white page, pill chips and buttons, wide
            // margins, quiet section labels. In the dark the shadow gives way to a lift, because
            // a shadow on a near-black ground is a shadow nobody sees.
            DesignTheme.NIEVE -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.nieveDark else UniPalettes.nieveLight,
                shapes = UniShapes.apple,
                spacing = UniSpacing(page = 22.dp, gap = 16.dp, gapSmall = 10.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = false, labelLetterSpacing = 0.1.sp, labelQuiet = true),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.RAIL, workspaceColumns = 1, cardsAs = CardStyle.CARD, rowsAs = CardStyle.CARD),
                elevation = if (dark) UniElevation(
                    ambient = 0.dp, ambientColor = Color.Transparent,
                    key = 0.dp, keyColor = Color.Transparent,
                    surfaceLift = .05f, hairline = 0.5.dp,
                ) else UniElevation(
                    ambient = 18.dp, ambientColor = Color(0xFF0B0F1A).copy(alpha = .55f),
                    key = 3.dp, keyColor = Color(0xFF0B0F1A).copy(alpha = .70f),
                    surfaceLift = 0f, hairline = 0.5.dp,
                ),
            )
            // Obsidiana: the precision of a developer tool. Compact rows between hairlines, small
            // radii, tracked capitals for labels, boxes in two columns and nothing that floats.
            DesignTheme.OBSIDIANA -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.obsidianaDark else UniPalettes.obsidianaLight,
                shapes = UniShapes.apple,
                spacing = UniSpacing(page = 16.dp, gap = 10.dp, gapSmall = 6.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = FontFamily.SansSerif, labelUppercase = true, labelLetterSpacing = 1.2.sp),
                layout = UniLayout(density = RowDensity.COMPACT, workspacesAs = WorkspaceLayout.GRID, workspaceColumns = 2, cardsAs = CardStyle.CARD, rowsAs = CardStyle.HAIRLINE),
                elevation = UniElevation.flat,
            )
            // Arena: editorial warmth. Serif headlines, roomy cards on a warm shadow, pill chips,
            // labels in sentence case and the boxes as a rail of tiles. In the dark the shadow
            // gives way to a lift, as in Nieve.
            DesignTheme.ARENA -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.arenaDark else UniPalettes.arenaLight,
                shapes = UniShapes.apple,
                spacing = UniSpacing(page = 22.dp, gap = 14.dp, gapSmall = 8.dp),
                type = UniType(headlineFamily = FontFamily.Serif, identifierFamily = FontFamily.SansSerif, labelUppercase = false, labelLetterSpacing = 0.2.sp),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.RAIL, workspaceColumns = 1, cardsAs = CardStyle.CARD, rowsAs = CardStyle.CARD),
                elevation = if (dark) UniElevation(
                    ambient = 0.dp, ambientColor = Color.Transparent,
                    key = 0.dp, keyColor = Color.Transparent,
                    surfaceLift = .04f, hairline = 0.5.dp,
                ) else UniElevation(
                    ambient = 14.dp, ambientColor = Color(0xFF5A3A1F).copy(alpha = .30f),
                    key = 2.dp, keyColor = Color(0xFF3D2B1F).copy(alpha = .40f),
                    surfaceLift = 0f, hairline = 0.5.dp,
                ),
            )
            // Lima: bento. Chunky rounded tiles in two columns, names and numbers in JetBrains Mono,
            // tracked capitals and flat fills: the tiles are told apart by their fill, not a shadow.
            DesignTheme.LIMA -> UniTokens(
                theme = theme,
                colors = if (dark) UniPalettes.limaDark else UniPalettes.limaLight,
                shapes = UniShapes.apple,
                spacing = UniSpacing(page = 16.dp, gap = 12.dp, gapSmall = 8.dp),
                type = UniType(headlineFamily = FontFamily.SansSerif, identifierFamily = UniFonts.mono, labelUppercase = true, labelLetterSpacing = 1.sp),
                layout = UniLayout(density = RowDensity.COMFORTABLE, workspacesAs = WorkspaceLayout.GRID, workspaceColumns = 2, cardsAs = CardStyle.CARD, rowsAs = CardStyle.CARD),
                elevation = UniElevation.flat,
            )
        }
    }
}
