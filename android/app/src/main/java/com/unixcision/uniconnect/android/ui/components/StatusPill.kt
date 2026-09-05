package com.unixcision.uniconnect.android.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
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
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.ui.Brand

enum class PillTone(val color: Color, val pulses: Boolean) {
    Live(Brand.Mint, true), Busy(Brand.Cyan, true), Idle(Brand.Muted, false), Warning(Brand.Amber, false), Danger(Brand.Coral, false),
}

/** Compact state badge with a dot that pulses only for live states; text stays readable on every tone. */
@Composable
fun StatusPill(text: String, tone: PillTone, modifier: Modifier = Modifier) {
    val alpha = if (tone.pulses) {
        val transition = rememberInfiniteTransition(label = "pill-pulse")
        val value by transition.animateFloat(1f, .35f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "pill-alpha")
        value
    } else 1f
    Row(
        modifier.background(tone.color.copy(alpha = .12f), CircleShape).border(1.dp, tone.color.copy(alpha = .35f), CircleShape)
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(7.dp).alpha(alpha).background(tone.color, CircleShape))
        Text(text, style = MaterialTheme.typography.labelSmall, color = tone.color, fontWeight = FontWeight.SemiBold)
    }
}
