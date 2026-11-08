package com.unixcision.uniconnect.android.ui.design.obsidiana

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusTarget
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * The few pieces every Obsidiana screen is built from: panels of rows split by hairlines, tracked
 * capitals, key caps and a segmented control. Kept here so the three screens read as one tool.
 */

/**
 * JetBrains Mono, already bundled for the terminal. Obsidiana sets numbers, addresses, key caps and
 * workspace names in it, the way a developer tool does; names of machines and windows stay in
 * the theme's identifier face.
 */
internal val ObsidianaMono = FontFamily(Font(R.font.jetbrains_mono))

/** Where a row sits in its panel: the ends carry the panel's corners, the rows between are plain. */
internal enum class Segment {
    ONLY, FIRST, MIDDLE, LAST;

    /** Only the last row closes the panel; every other row leaves its bottom to the next one's rule. */
    val closes: Boolean get() = this == ONLY || this == LAST

    fun shape(radius: Dp): Shape = when (this) {
        ONLY -> ContinuousRoundedShape(radius)
        FIRST -> ContinuousRoundedShape(radius, radius, 0.dp, 0.dp)
        MIDDLE -> RectangleShape
        LAST -> ContinuousRoundedShape(0.dp, 0.dp, radius, radius)
    }

    companion object {
        fun of(index: Int, count: Int): Segment = when {
            count <= 1 -> ONLY
            index == 0 -> FIRST
            index == count - 1 -> LAST
            else -> MIDDLE
        }
    }
}

/** The corner of an Obsidiana panel: the theme's button radius, as small as the mock-up's 12. */
internal val panelRadius: Dp @Composable get() = UniTheme.shapes.buttonRadius

/** The shape of one row of a panel, built once per position. */
@Composable
internal fun rememberSegmentShape(segment: Segment): Shape {
    val radius = panelRadius
    return remember(segment, radius) { segment.shape(radius) }
}

/** The whole panel as one shape, for blocks that are not split into lazy rows. */
@Composable
internal fun rememberPanelShape(): Shape {
    val radius = panelRadius
    return remember(radius) { ContinuousRoundedShape(radius) }
}

/**
 * One row of a panel: its fill and the inside half of a hairline edge. Consecutive rows stack
 * into one bordered block with a single rule between them, while each stays its own lazy item,
 * so a list of a hundred windows never lays out as one block.
 */
internal fun Modifier.panelSegment(segment: Segment, shape: Shape, fill: Color, rule: Color): Modifier = this
    .clip(shape)
    .background(fill)
    .drawWithCache {
        val stroke = 1.dp.toPx()
        val outline = shape.createOutline(size, layoutDirection, this)
        // The bottom edge belongs to the next row's top rule, so a row that does not close the
        // panel stops one stroke short; the clip already hides the outer half of the stroke.
        val bottom = if (segment.closes) size.height else size.height - stroke
        onDrawWithContent {
            drawContent()
            clipRect(bottom = bottom) { drawOutline(outline, rule, style = Stroke(stroke * 2)) }
        }
    }

/** A whole panel in one piece: fill and a neutral edge, for blocks short enough to lay out at once. */
internal fun Modifier.panel(shape: Shape, fill: Color, rule: Color): Modifier = this.clip(shape).background(fill).border(1.dp, rule, shape)

/** A one pixel rule across its parent. */
@Composable
internal fun Hairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(UniTheme.colors.outline))
}

/** A one pixel rule down its parent, between the cells of a strip. */
@Composable
internal fun VerticalHairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxHeight().width(1.dp).background(UniTheme.colors.outline))
}

/** A state dot. */
@Composable
internal fun Dot(color: Color, modifier: Modifier = Modifier, size: Dp = 7.dp) {
    Box(modifier.size(size).background(color, CircleShape))
}

/** The hollow ring of a window whose AI rests: present, but quiet. */
@Composable
internal fun IdleRing(modifier: Modifier = Modifier) {
    Box(modifier.size(8.dp).border(1.5.dp, UniTheme.colors.muted, CircleShape))
}

/** A section label in tracked capitals and the electric violet, as the theme asks. */
@Composable
internal fun CapsLabel(text: String, modifier: Modifier = Modifier, color: Color = UniTheme.colors.accent, textAlign: TextAlign? = null) {
    Text(
        if (UniTheme.type.labelUppercase) text.uppercase() else text,
        modifier,
        style = MaterialTheme.typography.labelSmall,
        textAlign = textAlign,
        fontWeight = FontWeight.SemiBold,
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/**
 * A small monospaced tag: a key cap, the AI of a window, the network. [edge] is null on a filled
 * accent surface, where a rule would only add noise.
 */
@Composable
internal fun Tag(
    text: String,
    modifier: Modifier = Modifier,
    fill: Color = UniTheme.colors.surfaceRaised,
    content: Color = UniTheme.colors.muted,
    edge: Color? = UniTheme.colors.outline,
) {
    val shape = UniTheme.shapes.chip
    Box(
        modifier.defaultMinSize(minWidth = 22.dp).clip(shape).background(fill)
            .then(if (edge != null) Modifier.border(1.dp, edge, shape) else Modifier)
            .padding(horizontal = 6.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = ObsidianaMono,
            fontSize = 11.sp,
            lineHeight = 14.sp,
            letterSpacing = 0.sp,
            color = content,
            maxLines = 1,
        )
    }
}

/**
 * The segmented control of the mock-up: a sunken track with the chosen option raised on it. A
 * disabled option stays in place, faded, so the control never changes shape under the thumb.
 */
@Composable
internal fun <T> SegmentedTabs(
    options: List<T>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    enabled: (T) -> Boolean = { true },
    label: @Composable RowScope.(option: T, chosen: Boolean) -> Unit,
) {
    val colors = UniTheme.colors
    val track = UniTheme.shapes.chip
    val chipRadius = UniTheme.shapes.chipRadius
    // The thumb sits two points inside the track, so its corner is the track's minus that inset.
    val thumb = remember(chipRadius) { ContinuousRoundedShape(chipRadius - 2.dp) }
    Row(
        modifier.fillMaxWidth().height(50.dp).clip(track).background(colors.surface).border(1.dp, colors.outline, track)
            .padding(2.dp).selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEach { option ->
            val chosen = option == selected
            val on = enabled(option)
            Row(
                Modifier.weight(1f).fillMaxHeight().clip(thumb)
                    .then(if (chosen) Modifier.background(colors.surfaceRaised).border(1.dp, colors.outline, thumb) else Modifier)
                    .selectable(selected = chosen, enabled = on, role = Role.Tab, onClick = { onSelect(option) })
                    .alpha(if (on) 1f else .45f)
                    .padding(horizontal = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) { label(option, chosen) }
        }
    }
}

/**
 * Lets a hardware keyboard reach the key caps a screen prints: a bare letter runs its action. A
 * text field inside keeps the letters typed into it, because it consumes them before they bubble
 * up here.
 */
@Composable
internal fun ShortcutHost(bindings: Map<Key, () -> Unit>, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val focus = remember { FocusRequester() }
    val current by rememberUpdatedState(bindings)
    Box(
        modifier
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown || event.isCtrlPressed || event.isMetaPressed || event.isAltPressed) return@onKeyEvent false
                val action = current[event.key] ?: return@onKeyEvent false
                action()
                true
            }
            .focusRequester(focus)
            .focusTarget(),
        content = content,
    )
    // Without focus somewhere inside, a key never reaches this box.
    LaunchedEffect(focus) { runCatching { focus.requestFocus() } }
}
