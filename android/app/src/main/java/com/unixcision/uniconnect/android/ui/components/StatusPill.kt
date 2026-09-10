package com.unixcision.uniconnect.android.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.repeatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** The states a pill can announce; the colour comes from the theme at draw time. */
enum class PillTone(val pulses: Boolean) {
    Live(true), Busy(true), Idle(false), Warning(false), Danger(false);

    /** The theme's colour for this state. */
    val color: Color
        @Composable get() = when (this) {
            Live -> UniTheme.colors.success
            Busy -> UniTheme.colors.accent
            Idle -> UniTheme.colors.muted
            Warning -> UniTheme.colors.warning
            Danger -> UniTheme.colors.danger
        }
}

/** Compact state badge with a dot that beats when the state arrives and then holds still. */
@Composable
fun StatusPill(text: String, tone: PillTone, modifier: Modifier = Modifier) {
    val color = tone.color
    val shape = UniTheme.shapes.chip
    // The beat is deliberately finite. An endless pulse looks alive but forces the whole window to
    // redraw at the display's refresh rate for as long as it is on screen: on a Pixel 8 Pro that was
    // ~120 fps forever, half a core burnt on a still list, a warm phone and every other animation on
    // the device stuttering behind it. Motion belongs to the moment the state changes, not to the
    // state itself. Read inside `graphicsLayer` so each beat is a draw, never a recomposition.
    val pulse = remember { Animatable(1f) }
    LaunchedEffect(tone) {
        if (!tone.pulses) return@LaunchedEffect
        pulse.snapTo(1f)
        pulse.animateTo(DIM_ALPHA, repeatable(PULSE_BEATS, tween(BEAT_MILLIS), RepeatMode.Reverse))
        pulse.snapTo(1f)
    }
    Row(
        modifier.background(color.copy(alpha = .12f), shape).border(1.dp, color.copy(alpha = .35f), shape)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(7.dp).graphicsLayer { alpha = pulse.value }.background(color, CircleShape))
        Text(if (UniTheme.type.labelUppercase) text.uppercase() else text, style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.SemiBold)
    }
}

/** How faint the dot gets at the bottom of a beat. */
private const val DIM_ALPHA = .35f
/** Half-beats: an even count ends the animation back at full strength. */
private const val PULSE_BEATS = 6
/** Duration of one half-beat. */
private const val BEAT_MILLIS = 900
