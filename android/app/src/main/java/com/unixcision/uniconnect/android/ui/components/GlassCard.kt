package com.unixcision.uniconnect.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.theme.CardStyle
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The one surface a screen groups content on: a card is a fill with an edge, a hairline block is
 * the content above a rule, with no fill at all. [style] defaults to the theme's choice for
 * message blocks; list rows pass the theme's row style.
 *
 * A flat theme draws the card exactly as it always has, a one pixel outline and nothing else. A
 * floating theme (see `UniElevation`) casts two layers of shadow under it first, the wide faint
 * one and the short defined one, keeps the edge down to a barely visible hairline, and in the
 * dark, where no shadow reads, lifts the fill with a little white instead.
 *
 * [accent] echoes a box's tone or a live state: it tints the edge of a card and draws a thin bar
 * down the start edge of a hairline block. Where the edge is a hairline it is tinted harder, so a
 * half pixel still says what a whole one used to.
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = UniTheme.shapes.card,
    tint: Color = UniTheme.colors.surface,
    accent: Color? = null,
    onClick: (() -> Unit)? = null,
    style: CardStyle = UniTheme.layout.cardsAs,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = UniTheme.colors
    val elevation = UniTheme.elevation
    val base = if (style == CardStyle.HAIRLINE) {
        val rule = colors.outline
        modifier.drawBehind {
            val stroke = 1.dp.toPx()
            drawLine(rule, Offset(0f, size.height - stroke / 2), Offset(size.width, size.height - stroke / 2), stroke)
            if (accent != null) drawRect(accent, topLeft = Offset.Zero, size = Size(3.dp.toPx(), size.height))
        }
    } else {
        val edge = accent?.copy(alpha = if (elevation.hairline < 1.dp) .5f else .35f) ?: colors.outline
        modifier
            .then(if (elevation.ambient > 0.dp) Modifier.shadow(elevation.ambient, shape, clip = false, ambientColor = elevation.ambientColor, spotColor = elevation.ambientColor) else Modifier)
            .then(if (elevation.key > 0.dp) Modifier.shadow(elevation.key, shape, clip = false, ambientColor = elevation.keyColor, spotColor = elevation.keyColor) else Modifier)
            .clip(shape)
            .background(tint)
            .then(if (elevation.surfaceLift > 0f) Modifier.background(Color.White.copy(alpha = elevation.surfaceLift)) else Modifier)
            .border(elevation.hairline, edge, shape)
    }
    Box(if (onClick != null) base.clickable(onClick = onClick) else base) {
        Column(content = content)
    }
}
