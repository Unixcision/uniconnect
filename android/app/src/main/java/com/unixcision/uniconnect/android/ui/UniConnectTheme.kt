package com.unixcision.uniconnect.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color

object Brand {
    val Night = Color(0xFF070D20)
    val DeepBlue = Color(0xFF0C1738)
    val Surface = Color(0xFF101A32)
    val Cyan = Color(0xFF42DAF5)
    val Violet = Color(0xFF9D8BFF)
    val Text = Color(0xFFEEF3FF)
    val Muted = Color(0xFFA1AEC9)
    val Outline = Color(0xFF293650)
}

@Composable
fun UniConnectTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Brand.Cyan, onPrimary = Brand.Night,
            secondary = Brand.Violet, onSecondary = Brand.Night,
            background = Brand.Night, onBackground = Brand.Text,
            surface = Brand.Surface, onSurface = Brand.Text,
            surfaceVariant = Brand.DeepBlue, onSurfaceVariant = Brand.Muted,
            outline = Brand.Outline, error = Color(0xFFFFB4AB),
        ),
        typography = Typography(),
    ) {
        CompositionLocalProvider(LocalContentColor provides Brand.Text, content = content)
    }
}
