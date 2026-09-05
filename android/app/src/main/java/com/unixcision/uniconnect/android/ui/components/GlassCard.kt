package com.unixcision.uniconnect.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.Brand

/**
 * A translucent card with a light gradient edge, the one expressive surface of the app.
 * [accent] adds a soft glow in the top-start corner, used to echo a box's tone or a live state.
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
    tint: Color = Brand.Surface,
    accent: Color? = null,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val edge = Brush.linearGradient(listOf(Brand.GlassTop, Brand.GlassBottom))
    val fill = Brush.verticalGradient(listOf(tint.copy(alpha = .94f), tint.copy(alpha = .78f)))
    val base = modifier.clip(shape).background(fill).border(1.dp, edge, shape)
    Box(if (onClick != null) base.clickable(onClick = onClick) else base) {
        if (accent != null) Box(Modifier.matchParentSize().drawBehind {
            drawCircle(
                Brush.radialGradient(listOf(accent.copy(alpha = .22f), Color.Transparent), center = Offset(0f, 0f), radius = size.width * .55f),
                radius = size.width * .55f, center = Offset(0f, 0f),
            )
        })
        Column(content = content)
    }
}
