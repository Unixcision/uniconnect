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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.theme.CardStyle
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The one surface a screen groups content on. In a theme that draws cards it is a translucent
 * card with a light gradient edge; in a hairline theme it is the content between two rules,
 * with no fill at all. [accent] echoes a box's tone or a live state: a soft glow in the
 * top-start corner of a card, a thin bar down the start edge of a hairline block.
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = UniTheme.shapes.card,
    tint: Color = UniTheme.colors.surface,
    accent: Color? = null,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = UniTheme.colors
    val base = if (UniTheme.layout.cardsAs == CardStyle.HAIRLINE) {
        val rule = colors.outline
        modifier.drawBehind {
            val stroke = 1.dp.toPx()
            drawLine(rule, Offset(0f, size.height - stroke / 2), Offset(size.width, size.height - stroke / 2), stroke)
            if (accent != null) drawRect(accent, topLeft = Offset.Zero, size = Size(3.dp.toPx(), size.height))
        }
    } else {
        val edge = Brush.linearGradient(listOf(colors.glassTop, colors.glassBottom))
        val fill = Brush.verticalGradient(listOf(tint.copy(alpha = .94f), tint.copy(alpha = .78f)))
        modifier.clip(shape).background(fill).border(1.dp, edge, shape)
    }
    val filled = UniTheme.layout.cardsAs == CardStyle.CARD
    Box(if (onClick != null) base.clickable(onClick = onClick) else base) {
        if (accent != null && filled) Box(Modifier.matchParentSize().drawBehind {
            drawCircle(
                Brush.radialGradient(listOf(accent.copy(alpha = .22f), Color.Transparent), center = Offset(0f, 0f), radius = size.width * .55f),
                radius = size.width * .55f, center = Offset(0f, 0f),
            )
        })
        Column(content = content)
    }
}
