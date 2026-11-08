package com.unixcision.uniconnect.android.ui.design.arena

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.monogram
import com.unixcision.uniconnect.android.ui.components.themedTone
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * The pieces Arena's three screens share: the serif section title, the prose that tells how
 * things are with its numbers picked out, the serif monogram and the reply button.
 */

/** `%1$s`, `%2$s`…: where a styled part goes in a sentence kept whole in the resources. */
private val PLACEHOLDER = Regex("%(\\d+)\\\$s")

/**
 * [template] with each `%N$s` replaced by the Nth of [parts] in its own style. The sentence stays
 * whole in the resources, plurals and all; only the numbers and names stand out.
 */
internal fun styled(template: String, vararg parts: Pair<String, SpanStyle>): AnnotatedString = buildAnnotatedString {
    var from = 0
    PLACEHOLDER.findAll(template).forEach { match ->
        append(template.substring(from, match.range.first))
        parts.getOrNull(match.groupValues[1].toInt() - 1)?.let { (text, style) -> withStyle(style) { append(text) } }
        from = match.range.last + 1
    }
    append(template.substring(from))
}

/** The magazine's body copy: serif, roomy and muted, so the picked-out numbers carry the eye. */
@Composable
internal fun arenaProseStyle(): TextStyle = MaterialTheme.typography.bodyLarge.copy(
    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.Medium,
    fontSize = 18.sp, lineHeight = 27.sp, color = UniTheme.colors.muted,
)

/**
 * The windows and what their AIs do, in one sentence: «Hay 94 ventanas abiertas, 8 IAs trabajando
 * y 1 te espera.» Without a live connection the activity is a picture of the past, so it says
 * only how many windows the last reading found.
 */
@Composable
internal fun arenaActivityProse(windows: Int, working: Int, waiting: Int, live: Boolean): AnnotatedString {
    val colors = UniTheme.colors
    val strong = SpanStyle(color = colors.text)
    if (windows == 0) return AnnotatedString(stringResource(R.string.arena_prose_no_windows))
    val windowsPart = pluralStringResource(R.plurals.arena_prose_windows, windows, windows) to strong
    if (!live) return styled(pluralStringResource(R.plurals.arena_prose_stale, windows), windowsPart)
    if (working == 0 && waiting == 0) return styled(pluralStringResource(R.plurals.arena_prose_quiet, windows), windowsPart)
    val workingPart = (if (working > 0) pluralStringResource(R.plurals.arena_prose_working, working, working) else stringResource(R.string.arena_prose_working_none)) to strong
    val waitingPart = if (waiting > 0) pluralStringResource(R.plurals.arena_prose_waiting, waiting, waiting) to SpanStyle(color = colors.warning)
    else stringResource(R.string.arena_prose_waiting_none) to strong
    return styled(pluralStringResource(R.plurals.arena_prose_activity, windows), windowsPart, workingPart, waitingPart)
}

/** The home's paragraph: «2 de 2 máquinas conectadas.» and then the windows and their AIs. */
@Composable
internal fun arenaHomeProse(total: HomeSummary): AnnotatedString {
    val strong = SpanStyle(color = UniTheme.colors.text)
    val machines = pluralStringResource(R.plurals.arena_prose_machines, total.machines, total.connected, total.machines)
    val first = styled(pluralStringResource(R.plurals.arena_prose_connected, total.machines), machines to strong)
    val second = arenaActivityProse(total.windows, total.working, total.waiting, live = total.connected > 0)
    return buildAnnotatedString {
        append(first)
        append(" ")
        append(second)
    }
}

/** A section's title in the serif: «Actividad reciente», «Tus máquinas», «Espacios». */
@Composable
internal fun ArenaSectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text, modifier,
        style = MaterialTheme.typography.titleLarge.copy(fontSize = 21.sp, lineHeight = 26.sp, letterSpacing = (-0.2).sp),
        fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = UniTheme.colors.text,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/**
 * A machine's initials set in the serif on a pale wash of its tone, like a drop cap. Drawn here
 * rather than with `BoxMonogram` because Arena's tile is flat and typographic: no border, no
 * gradient and no scale.
 */
@Composable
internal fun ArenaMonogram(name: String, size: Dp, shape: Shape, dimmed: Boolean) {
    val tone = themedTone(name)
    Box(Modifier.size(size).background(tone.copy(alpha = if (dimmed) .08f else .14f), shape), contentAlignment = Alignment.Center) {
        Text(
            monogram(name),
            color = tone.copy(alpha = if (dimmed) .6f else 1f),
            fontFamily = UniTheme.type.headlineFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = (size.value * .41f).sp,
            letterSpacing = (-0.2).sp,
            maxLines = 1,
        )
    }
}

/** A coloured dot and a short line in the same colour: «● 2 de 2 conectadas». */
@Composable
internal fun ArenaDotLabel(text: String, tone: Color, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(7.dp).background(tone, CircleShape))
        Text(
            text, style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
            color = tone, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The words and colour of a machine's link. */
@Composable
private fun stateLook(state: MachineState): Pair<String, Color> {
    val colors = UniTheme.colors
    return when (state) {
        MachineState.CONNECTED -> stringResource(R.string.connected_machine) to colors.success
        MachineState.CHECKING -> stringResource(R.string.checking_machine) to colors.accent
        MachineState.SAVED -> stringResource(R.string.saved_machine) to colors.muted
    }
}

/** A machine's link as a line under its name: «● Conectada». */
@Composable
internal fun ArenaStatus(state: MachineState, modifier: Modifier = Modifier) {
    val (text, tone) = stateLook(state)
    ArenaDotLabel(text, tone, modifier)
}

/** A machine's link as a small tinted label, for the head of the machine screen. */
@Composable
internal fun ArenaStateChip(state: MachineState, modifier: Modifier = Modifier) {
    val (text, tone) = stateLook(state)
    Row(
        modifier.background(tone.copy(alpha = .12f), UniTheme.shapes.chip).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(7.dp).background(tone, CircleShape))
        Text(
            text, style = MaterialTheme.typography.labelLarge.copy(fontSize = 13.sp, lineHeight = 18.sp),
            color = tone, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** «Responder»: the one filled button of a screen, in terracotta, on whatever waits for the reader. */
@Composable
internal fun ArenaReplyButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    Button(
        onClick = onClick,
        modifier = modifier.height(44.dp),
        shape = UniTheme.shapes.materialButton,
        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        contentPadding = PaddingValues(horizontal = 14.dp),
    ) {
        Text(
            stringResource(R.string.design_reply), style = MaterialTheme.typography.labelLarge.copy(fontSize = 14.sp),
            fontWeight = FontWeight.SemiBold, maxLines = 1,
        )
    }
}
