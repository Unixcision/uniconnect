package com.unixcision.uniconnect.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.ui.theme.UniTokens
import kotlin.math.abs

/**
 * Deterministic tone for a box or machine name, stable across launches like the desktop rail.
 *
 * Every theme carries the same number of [tones], so a name lands in the same slot whichever
 * palette is passed. Without a theme in reach (a notification icon) the shipped dark palette is
 * used, which is what the notice tray shows on any phone.
 */
fun boxTone(seed: String, tones: List<Color> = UniTokens.tokensFor(DesignTheme.SERENO, dark = true).colors.tones): Color =
    tones[abs(seed.lowercase().hashCode()) % tones.size]

/** [boxTone] in the palette of the theme in force. */
@Composable
fun themedTone(seed: String): Color = boxTone(seed, UniTheme.colors.tones)

/**
 * The corner of an identity tile of [size]: a 24 dp card radius gives the desktop's squircle,
 * squarer themes get a squarer tile. Shared with the tile that offers a new box.
 */
@Composable
fun monogramShape(size: Dp): Shape = RoundedCornerShape(size * (.36f * (UniTheme.shapes.cardRadius / 24.dp).coerceAtMost(1f)))

/** Two-character monogram: initials of the first two words, or the first two characters. */
fun monogram(name: String): String {
    val words = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    val letters = if (words.size >= 2) "${words[0].first()}${words[1].first()}" else name.trim().take(2)
    return letters.uppercase().ifEmpty { "·" }
}

/**
 * Identity tile, as round as the theme's cards. Selection is expressed through fill, border and
 * scale only; the monogram keeps its contrast whether the tile is selected, idle or [dimmed]
 * (disconnected).
 */
@Composable
fun BoxMonogram(name: String, modifier: Modifier = Modifier, size: Dp = 56.dp, selected: Boolean = false, dimmed: Boolean = false, tone: Color = themedTone(name)) {
    val scale by animateFloatAsState(if (selected) 1f else .92f, label = "monogram-scale")
    val shape = monogramShape(size)
    val fill = if (selected) Brush.linearGradient(listOf(tone, tone.copy(alpha = .75f)))
    else Brush.linearGradient(listOf(tone.copy(alpha = if (dimmed) .12f else .3f), tone.copy(alpha = if (dimmed) .06f else .16f)))
    Box(
        modifier.size(size).scale(scale).background(fill, shape)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) Color.White.copy(alpha = .55f) else tone.copy(alpha = if (dimmed) .2f else .45f), shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            monogram(name),
            color = if (selected) UniTheme.colors.onAccent else tone.copy(alpha = if (dimmed) .7f else 1f),
            fontFamily = UniTheme.type.identifierFamily,
            fontWeight = FontWeight.Black,
            fontSize = (size.value * .34f).sp,
            letterSpacing = (-0.5).sp,
        )
    }
}
