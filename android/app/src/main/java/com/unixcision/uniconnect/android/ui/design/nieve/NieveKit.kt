package com.unixcision.uniconnect.android.ui.design.nieve

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.WebAsset
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * The pieces every Nieve screen is built from: the inset grouped list of Apple's Settings. A
 * group is a white block on the page, its rows split by hairlines indented to where the text
 * starts, with a small header above it and, now and then, a footnote below.
 *
 * A long group (the windows of a workspace) is not one block but one lazy item per row, so
 * seventy windows never compose at once: each row draws its own slot of the group, the first
 * rounding the top and the last the bottom. Nothing casts a shadow, so the slots meet seamlessly.
 */

/** Where a row sits in its group, which decides the corners it rounds and whether a rule tops it. */
internal enum class NieveSlot(val roundsTop: Boolean, val roundsBottom: Boolean) {
    SINGLE(true, true), FIRST(true, false), MIDDLE(false, false), LAST(false, true);

    companion object {
        /** The slot of row [index] in a group of [count] rows. */
        fun of(index: Int, count: Int): NieveSlot = when {
            count <= 1 -> SINGLE
            index == 0 -> FIRST
            index == count - 1 -> LAST
            else -> MIDDLE
        }
    }
}

/** Nieve's type scale, Apple's: a large title that leads, 15 and 13 point rows, quiet headers. */
internal object NieveText {
    val largeTitle: TextStyle
        @Composable get() = MaterialTheme.typography.displaySmall.copy(
            fontFamily = UniTheme.type.headlineFamily, fontSize = 34.sp, lineHeight = 40.sp,
            fontWeight = FontWeight.Bold, letterSpacing = (-0.6).sp,
        )
    val barTitle: TextStyle
        @Composable get() = MaterialTheme.typography.titleMedium.copy(fontSize = 16.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold)
    val barNote: TextStyle
        @Composable get() = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium)
    val eyebrow: TextStyle
        @Composable get() = MaterialTheme.typography.labelLarge.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.3.sp)
    val header: TextStyle
        @Composable get() = MaterialTheme.typography.labelLarge.copy(
            fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Medium, letterSpacing = UniTheme.type.labelLetterSpacing,
        )
    val headline: TextStyle
        @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.1).sp)
    val title: TextStyle
        @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.1).sp)
    val body: TextStyle
        @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 20.sp, letterSpacing = 0.sp)
    val menu: TextStyle
        @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 16.sp, lineHeight = 21.sp, letterSpacing = (-0.1).sp)
    val back: TextStyle
        @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 22.sp, letterSpacing = (-0.1).sp)
    val detail: TextStyle
        @Composable get() = MaterialTheme.typography.bodyMedium.copy(fontSize = 13.sp, lineHeight = 18.sp, letterSpacing = 0.sp)
    val number: TextStyle
        @Composable get() = MaterialTheme.typography.headlineMedium.copy(
            fontFamily = UniTheme.type.identifierFamily, fontSize = 28.sp, lineHeight = 34.sp,
            fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp, fontFeatureSettings = "tnum",
        )
}

/**
 * The hairline between rows. The theme's outline is tuned for the edge of a card on the page;
 * between two white rows it would vanish, so the rule is the same neutral a little stronger.
 */
@Composable
internal fun nieveRuleColor(): Color = UniTheme.colors.outline.let { it.copy(alpha = (it.alpha * 2.5f).coerceAtMost(1f)) }

/** The shape of a row in [slot]: continuous corners only where the group has its own. */
@Composable
internal fun nieveSlotShape(slot: NieveSlot): Shape {
    val radius = UniTheme.shapes.cardRadius
    if (slot == NieveSlot.MIDDLE) return RectangleShape
    val top = if (slot.roundsTop) radius else 0.dp
    val bottom = if (slot.roundsBottom) radius else 0.dp
    return ContinuousRoundedShape(topStart = top, topEnd = top, bottomEnd = bottom, bottomStart = bottom)
}

/** A group's block, or one slot of it: inside the page margin, on the surface, rounded where the group is. */
@Composable
internal fun Modifier.nieveGroup(slot: NieveSlot = NieveSlot.SINGLE, margin: Dp = UniTheme.spacing.page): Modifier =
    this.padding(horizontal = margin).clip(nieveSlotShape(slot)).background(UniTheme.colors.surface)

/**
 * One row of a group. [rule] is how far from the start the hairline above it begins (null for the
 * first row, which has none); a long press is only wired when [onLongClick] is given.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun NieveRow(
    modifier: Modifier = Modifier,
    rule: Dp? = null,
    ruleEnd: Dp = 0.dp,
    minHeight: Dp = 60.dp,
    padding: PaddingValues = PaddingValues(start = 16.dp, end = 14.dp, top = 10.dp, bottom = 10.dp),
    highlight: Color? = null,
    onClickLabel: String? = null,
    onLongClick: (() -> Unit)? = null,
    onClick: (() -> Unit)? = null,
    content: @Composable RowScope.() -> Unit,
) {
    val ruleColor = nieveRuleColor()
    val hairline = rule?.let { inset ->
        Modifier.drawBehind {
            val stroke = maxOf(1f, 0.5.dp.toPx())
            val ltr = layoutDirection == LayoutDirection.Ltr
            val start = if (ltr) inset.toPx() else ruleEnd.toPx()
            val end = size.width - if (ltr) ruleEnd.toPx() else inset.toPx()
            drawLine(ruleColor, Offset(start, stroke / 2f), Offset(end, stroke / 2f), stroke)
        }
    } ?: Modifier
    val click = when {
        onClick == null -> Modifier
        onLongClick != null -> Modifier.combinedClickable(onClickLabel = onClickLabel, onLongClick = onLongClick, onClick = onClick)
        else -> Modifier.clickable(onClickLabel = onClickLabel, onClick = onClick)
    }
    Row(
        modifier
            .fillMaxWidth()
            .then(if (highlight != null) Modifier.background(highlight) else Modifier)
            .then(hairline)
            .then(click)
            .heightIn(min = minHeight)
            .padding(padding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        content = content,
    )
}

/** The small header over a group, aligned with the text of its rows. */
@Composable
internal fun NieveHeader(
    title: String,
    modifier: Modifier = Modifier,
    margin: Dp = UniTheme.spacing.page,
    top: Dp = 24.dp,
    trailing: String? = null,
) {
    val muted = UniTheme.colors.muted
    Row(
        modifier.fillMaxWidth().padding(start = margin + 16.dp, end = margin + 16.dp, top = top, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (UniTheme.type.labelUppercase) title.uppercase() else title, Modifier.weight(1f),
            style = NieveText.header, color = muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        if (trailing != null) Text(trailing, Modifier.padding(start = 12.dp), style = NieveText.detail, color = muted, maxLines = 1)
    }
}

/** The footnote under a group: what a row could not say without crowding it. */
@Composable
internal fun NieveFooter(text: String, modifier: Modifier = Modifier, color: Color = UniTheme.colors.muted, margin: Dp = UniTheme.spacing.page) {
    Text(
        text, modifier.fillMaxWidth().padding(start = margin + 16.dp, end = margin + 16.dp, top = 8.dp),
        style = NieveText.detail, color = color,
    )
}

/** The rounded square that holds a row's icon. */
@Composable
internal fun NieveTile(size: Dp, fill: Color, content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.size(size).background(fill, UniTheme.shapes.chip), contentAlignment = Alignment.Center, content = content)
}

/** A status dot. */
@Composable
internal fun NieveDot(color: Color, size: Dp = 8.dp) {
    Box(Modifier.size(size).background(color, CircleShape))
}

/** The disclosure chevron at the end of a row that leads somewhere. */
@Composable
internal fun NieveChevron() {
    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(20.dp), tint = UniTheme.colors.muted.copy(alpha = .6f))
}

/** «Responder» at the end of a waiting row, in the accent like any action Apple puts in a row. */
@Composable
internal fun NieveReply(label: String) {
    Text(label, style = NieveText.title, color = UniTheme.colors.accent, maxLines = 1)
}

/** What a machine's link is called. */
@Composable
internal fun nieveStateText(state: MachineState): String = stringResource(
    when (state) {
        MachineState.CONNECTED -> R.string.connected_machine
        MachineState.CHECKING -> R.string.checking_machine
        MachineState.SAVED -> R.string.saved_machine
    },
)

/** The colour of a machine's status dot. */
@Composable
internal fun nieveStateTone(state: MachineState): Color = when (state) {
    MachineState.CONNECTED -> UniTheme.colors.success
    MachineState.CHECKING -> UniTheme.colors.accent
    MachineState.SAVED -> UniTheme.colors.muted
}

/**
 * «● Conectada · 100.120.128.58:8855». The state is measured first, so a narrow row shortens the
 * address, never the state.
 */
@Composable
internal fun NieveStateLine(state: MachineState, address: String, style: TextStyle, modifier: Modifier = Modifier, dot: Dp = 7.dp) {
    val colors = UniTheme.colors
    val tone = nieveStateTone(state)
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        NieveDot(tone, dot)
        Text(
            nieveStateText(state), Modifier.padding(start = 6.dp), style = style, fontWeight = FontWeight.Medium,
            color = if (state == MachineState.SAVED) colors.muted else tone, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(" · ", style = style, color = colors.muted, maxLines = 1)
        Text(
            address, Modifier.weight(1f, fill = false), style = style, fontFamily = UniTheme.type.identifierFamily,
            color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** What a number of the summary counts, which decides the glyph beside it. */
internal enum class NieveStatKind { WORKSPACES, WINDOWS, WORKING, WAITING }

/** One number of the summary block. */
@Immutable
internal data class NieveStat(val kind: NieveStatKind, val value: Int, val label: String)

/**
 * The numbers that matter, side by side between hairlines, as the first row of a group. Columns
 * share the width evenly and keep one height, so a label that wraps never misaligns the numbers.
 */
@Composable
internal fun NieveStatRow(stats: List<NieveStat>, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    val rule = nieveRuleColor()
    Row(modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        stats.forEachIndexed { index, stat ->
            if (index > 0) Box(Modifier.align(Alignment.CenterVertically).width(0.5.dp).height(44.dp).background(rule))
            Column(Modifier.weight(1f).fillMaxHeight().padding(start = 14.dp, end = 8.dp, top = 14.dp, bottom = 14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stat.value.toString(), style = NieveText.number, maxLines = 1)
                    NieveStatMark(stat)
                }
                Text(stat.label, Modifier.padding(top = 2.dp), style = NieveText.detail, color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** The glyph beside a number: plain for counts, the activity mark only when something is going on. */
@Composable
private fun NieveStatMark(stat: NieveStat) {
    val muted = UniTheme.colors.muted
    when (stat.kind) {
        NieveStatKind.WORKSPACES -> Icon(Icons.Rounded.GridView, null, Modifier.size(18.dp), tint = muted)
        NieveStatKind.WINDOWS -> Icon(Icons.Rounded.WebAsset, null, Modifier.size(18.dp), tint = muted)
        NieveStatKind.WORKING -> if (stat.value > 0) ActivityMark(ActivityState.WORKING, size = 16.dp)
        NieveStatKind.WAITING -> if (stat.value > 0) ActivityMark(ActivityState.WAITING, size = 18.dp)
    }
}
