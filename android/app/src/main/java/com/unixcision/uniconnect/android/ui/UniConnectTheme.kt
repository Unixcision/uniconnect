package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * UniConnect palette: night blue ground, cyan/violet accents and a small set of semantic tones.
 * Boxes get a deterministic tone from [Tones], mirroring the desktop rail's monogram colours.
 */
object Brand {
    val Night = Color(0xFF070D20)
    val DeepBlue = Color(0xFF0C1738)
    val Surface = Color(0xFF101A32)
    val SurfaceHigh = Color(0xFF172441)
    val Cyan = Color(0xFF42DAF5)
    val Violet = Color(0xFF9D8BFF)
    val Mint = Color(0xFF5EEAD4)
    val Coral = Color(0xFFFF7A8A)
    val Amber = Color(0xFFFFC857)
    val Text = Color(0xFFEEF3FF)
    val Muted = Color(0xFFA1AEC9)
    val Outline = Color(0xFF293650)
    val GlassTop = Color(0x29FFFFFF)
    val GlassBottom = Color(0x0AFFFFFF)
    val Tones = listOf(Cyan, Violet, Mint, Amber, Coral, Color(0xFF7CC4FF), Color(0xFFF59EFF), Color(0xFFB6F36B))
}

private val UniConnectTypography = Typography().let { base ->
    base.copy(
        displaySmall = base.displaySmall.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp),
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp),
        headlineMedium = base.headlineMedium.copy(fontWeight = FontWeight.Bold),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.Bold),
        titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
        labelSmall = base.labelSmall.copy(letterSpacing = 0.8.sp),
    )
}

private val UniConnectShapes = Shapes(
    extraSmall = RoundedCornerShape(10.dp),
    small = RoundedCornerShape(14.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(26.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun UniConnectTheme(content: @Composable () -> Unit) {
    MaterialExpressiveTheme(
        colorScheme = darkColorScheme(
            primary = Brand.Cyan, onPrimary = Brand.Night,
            primaryContainer = Brand.Cyan.copy(alpha = .18f), onPrimaryContainer = Brand.Cyan,
            secondary = Brand.Violet, onSecondary = Brand.Night,
            secondaryContainer = Brand.Violet.copy(alpha = .2f), onSecondaryContainer = Brand.Text,
            tertiary = Brand.Mint, onTertiary = Brand.Night,
            background = Brand.Night, onBackground = Brand.Text,
            surface = Brand.Surface, onSurface = Brand.Text,
            surfaceVariant = Brand.DeepBlue, onSurfaceVariant = Brand.Muted,
            surfaceContainer = Brand.Surface, surfaceContainerHigh = Brand.SurfaceHigh,
            surfaceContainerHighest = Brand.SurfaceHigh, surfaceContainerLow = Brand.DeepBlue,
            outline = Brand.Outline, outlineVariant = Brand.Outline.copy(alpha = .6f),
            error = Brand.Coral, onError = Brand.Night,
            errorContainer = Brand.Coral.copy(alpha = .18f), onErrorContainer = Color(0xFFFFD2D8),
        ),
        motionScheme = MotionScheme.expressive(),
        shapes = UniConnectShapes,
        typography = UniConnectTypography,
    ) {
        CompositionLocalProvider(LocalContentColor provides Brand.Text, content = content)
    }
}
