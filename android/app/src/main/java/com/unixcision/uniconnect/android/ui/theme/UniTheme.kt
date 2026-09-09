package com.unixcision.uniconnect.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.domain.ColorMode
import com.unixcision.uniconnect.android.domain.DesignTheme

/** The tokens in force below a [UniTheme]; reading it outside one is a programming error. */
private val LocalUniTokens = staticCompositionLocalOf<UniTokens> { error("UniTheme is not applied above this composable") }

/** Where a screen reads its tokens from: `UniTheme.colors.accent`, `UniTheme.shapes.card`, and so on. */
object UniTheme {
    val tokens: UniTokens @Composable @ReadOnlyComposable get() = LocalUniTokens.current
    val colors: UniColors @Composable @ReadOnlyComposable get() = LocalUniTokens.current.colors
    val shapes: UniShapes @Composable @ReadOnlyComposable get() = LocalUniTokens.current.shapes
    val spacing: UniSpacing @Composable @ReadOnlyComposable get() = LocalUniTokens.current.spacing
    val type: UniType @Composable @ReadOnlyComposable get() = LocalUniTokens.current.type
    val layout: UniLayout @Composable @ReadOnlyComposable get() = LocalUniTokens.current.layout
}

/**
 * Dresses [content] in [theme], light or dark as [mode] says, and gives Material's own components
 * (sheets, switches, buttons, menus) a colour scheme, shapes and type derived from the same tokens
 * so nothing on screen keeps a colour of its own.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun UniTheme(theme: DesignTheme, mode: ColorMode, content: @Composable () -> Unit) {
    val dark = when (mode) {
        ColorMode.LIGHT -> false
        ColorMode.DARK -> true
        ColorMode.SYSTEM -> isSystemInDarkTheme()
    }
    val tokens = remember(theme, dark) { UniTokens.tokensFor(theme, dark) }
    CompositionLocalProvider(LocalUniTokens provides tokens) {
        MaterialExpressiveTheme(
            colorScheme = remember(tokens) { tokens.materialColorScheme() },
            motionScheme = MotionScheme.expressive(),
            shapes = remember(tokens) { tokens.materialShapes() },
            typography = remember(tokens) { tokens.materialTypography() },
        ) {
            CompositionLocalProvider(LocalContentColor provides tokens.colors.text, content = content)
        }
    }
}

private fun UniTokens.materialColorScheme(): ColorScheme {
    val c = colors
    val onErrorContainer = if (c.isDark) lerp(c.danger, Color.White, .45f) else c.danger
    val onAccentSoft = if (c.isDark) c.background else Color.White
    return if (c.isDark) darkColorScheme(
        primary = c.accent, onPrimary = c.onAccent,
        primaryContainer = c.accent.copy(alpha = .18f), onPrimaryContainer = c.accent,
        secondary = c.accentSoft, onSecondary = onAccentSoft,
        secondaryContainer = c.accentSoft.copy(alpha = .2f), onSecondaryContainer = c.text,
        tertiary = c.success, onTertiary = c.onAccent,
        background = c.background, onBackground = c.text,
        surface = c.surface, onSurface = c.text,
        surfaceVariant = c.surfaceRaised, onSurfaceVariant = c.muted,
        surfaceContainer = c.surface, surfaceContainerHigh = c.surfaceRaised,
        surfaceContainerHighest = c.surfaceRaised, surfaceContainerLow = c.background,
        surfaceContainerLowest = c.background,
        outline = c.outline, outlineVariant = c.outline.copy(alpha = .6f),
        error = c.danger, onError = c.onAccent,
        errorContainer = c.danger.copy(alpha = .18f), onErrorContainer = onErrorContainer,
    ) else lightColorScheme(
        primary = c.accent, onPrimary = c.onAccent,
        primaryContainer = c.accent.copy(alpha = .14f), onPrimaryContainer = c.accent,
        secondary = c.accentSoft, onSecondary = onAccentSoft,
        secondaryContainer = c.accentSoft.copy(alpha = .16f), onSecondaryContainer = c.text,
        tertiary = c.success, onTertiary = c.onAccent,
        background = c.background, onBackground = c.text,
        surface = c.surface, onSurface = c.text,
        surfaceVariant = c.surfaceRaised, onSurfaceVariant = c.muted,
        surfaceContainer = c.surface, surfaceContainerHigh = c.surfaceRaised,
        surfaceContainerHighest = c.surfaceRaised, surfaceContainerLow = c.background,
        surfaceContainerLowest = c.surface,
        outline = c.outline, outlineVariant = c.outline.copy(alpha = .6f),
        error = c.danger, onError = c.onAccent,
        errorContainer = c.danger.copy(alpha = .12f), onErrorContainer = onErrorContainer,
    )
}

private fun UniTokens.materialShapes() = Shapes(
    extraSmall = shapes.chip,
    small = shapes.button,
    medium = shapes.card,
    large = shapes.card,
    extraLarge = shapes.sheet,
)

private fun UniTokens.materialTypography(): Typography {
    val base = Typography()
    val headline = type.headlineFamily
    return base.copy(
        displaySmall = base.displaySmall.copy(fontFamily = headline, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp),
        headlineLarge = base.headlineLarge.copy(fontFamily = headline, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp),
        headlineMedium = base.headlineMedium.copy(fontFamily = headline, fontWeight = FontWeight.Bold),
        headlineSmall = base.headlineSmall.copy(fontFamily = headline, fontWeight = FontWeight.SemiBold),
        titleLarge = base.titleLarge.copy(fontFamily = headline, fontWeight = FontWeight.Bold),
        titleMedium = base.titleMedium.copy(fontFamily = headline, fontWeight = FontWeight.SemiBold),
        titleSmall = base.titleSmall.copy(fontFamily = headline, fontWeight = FontWeight.SemiBold),
        labelSmall = base.labelSmall.copy(letterSpacing = if (type.labelUppercase) 0.8.sp else 0.3.sp),
    )
}
