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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.theme.CardStyle
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The one surface a screen groups content on, flat in every theme: a card is a fill with a one
 * pixel outline, a hairline block is the content above a rule, with no fill at all. [style]
 * defaults to the theme's choice for message blocks; list rows pass the theme's row style.
 * [accent] echoes a box's tone or a live state: it tints the outline of a card and draws a thin
 * bar down the start edge of a hairline block.
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
    val base = if (style == CardStyle.HAIRLINE) {
        val rule = colors.outline
        modifier.drawBehind {
            val stroke = 1.dp.toPx()
            drawLine(rule, Offset(0f, size.height - stroke / 2), Offset(size.width, size.height - stroke / 2), stroke)
            if (accent != null) drawRect(accent, topLeft = Offset.Zero, size = Size(3.dp.toPx(), size.height))
        }
    } else {
        modifier.clip(shape).background(tint).border(1.dp, accent?.copy(alpha = .35f) ?: colors.outline, shape)
    }
    Box(if (onClick != null) base.clickable(onClick = onClick) else base) {
        Column(content = content)
    }
}
