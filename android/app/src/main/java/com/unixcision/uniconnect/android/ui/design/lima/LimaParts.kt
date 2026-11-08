package com.unixcision.uniconnect.android.ui.design.lima

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * The pieces every Lima screen is built from: flat tiles told apart by their fill, square icon
 * buttons, tracked eyebrows and small state chips. Nothing here casts a shadow.
 */

/** The bento's gutter: tighter than a list gap, so the tiles read as one panel. */
internal val LimaGutter = 10.dp

/** A tile or section eyebrow, in tracked capitals when the theme asks for them. */
@Composable
internal fun LimaEyebrow(text: String, modifier: Modifier = Modifier, color: Color = UniTheme.colors.muted) {
    Text(
        if (UniTheme.type.labelUppercase) text.uppercase() else text,
        modifier,
        style = MaterialTheme.typography.labelSmall,
        color = color,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * A 44 dp square button with continuous corners. The description sits on the button itself, so it
 * survives when [content] swaps the icon for a progress mark.
 */
@Composable
internal fun LimaSquareButton(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fill: Color = UniTheme.colors.surface,
    tint: Color = UniTheme.colors.text,
    enabled: Boolean = true,
    content: (@Composable () -> Unit)? = null,
) {
    Box(
        modifier.size(44.dp).clip(UniTheme.shapes.button).background(fill)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        if (content != null) content() else Icon(icon, null, Modifier.size(22.dp), tint = tint)
    }
}

/** The machine's mark: a computer on a flat tile, lit while the machine answers. */
@Composable
internal fun LimaMachineGlyph(size: Dp, fill: Color, tint: Color, modifier: Modifier = Modifier) {
    Box(
        modifier.size(size).background(fill, if (size > 44.dp) UniTheme.shapes.card else UniTheme.shapes.button),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Rounded.Computer, null, Modifier.size(size * .52f), tint = tint)
    }
}

/**
 * How a machine answers, as a dot and a word on a small tile; a turning mark while it is being
 * checked. The longer states may take two lines on a narrow tile rather than lose their end.
 */
@Composable
internal fun LimaStateChip(state: MachineState, fill: Color, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    val (label, tone) = when (state) {
        MachineState.CONNECTED -> R.string.connected_machine to colors.accent
        MachineState.CHECKING -> R.string.checking_machine to colors.text
        MachineState.SAVED -> R.string.saved_machine to colors.muted
    }
    Row(
        modifier.background(fill, UniTheme.shapes.chip).padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (state == MachineState.CHECKING) ActivityMark(ActivityState.WORKING, size = 10.dp, tone = colors.muted)
        else Box(Modifier.size(7.dp).background(if (state == MachineState.CONNECTED) colors.accent else colors.muted, CircleShape))
        Text(
            stringResource(label),
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
            color = tone,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** How many AIs are in [state], with the state's own mark: a turning arc or a raised hand. */
@Composable
internal fun LimaCountChip(state: ActivityState, count: Int, tone: Color, modifier: Modifier = Modifier) {
    Row(
        modifier.background(tone.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 7.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        ActivityMark(state, size = 12.dp, tone = tone)
        Text(
            count.toString(),
            style = MaterialTheme.typography.labelMedium,
            fontFamily = UniTheme.type.identifierFamily,
            fontWeight = FontWeight.Bold,
            color = tone,
        )
    }
}
