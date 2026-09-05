package com.unixcision.uniconnect.android.ui

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.ZoomIn
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.TerminalKeyEncoder
import com.unixcision.uniconnect.android.domain.TerminalModifiers
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import com.unixcision.uniconnect.android.ui.components.PillTone
import com.unixcision.uniconnect.android.ui.components.StatusPill

/**
 * Mirror of one desktop terminal. Fit mode shows the whole desktop screen and a vertical drag
 * scrolls the desktop scrollback; zoom mode pans a readable copy locally. Nothing here resizes
 * or restarts the desktop PTY.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TerminalScreen(
    snapshot: TerminalSnapshot?,
    loading: Boolean,
    error: Int?,
    errorDetail: String?,
    sending: Boolean,
    reconnecting: Boolean,
    connected: Boolean,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
    onScroll: (Int) -> Unit,
    onSend: (String, (Boolean) -> Unit) -> Unit,
) {
    var viewMode by rememberSaveable { mutableStateOf(ViewMode.FIT) }
    var keysVisible by rememberSaveable { mutableStateOf(false) }
    var ctrl by rememberSaveable { mutableStateOf(ModifierState.OFF) }
    var alt by rememberSaveable { mutableStateOf(ModifierState.OFF) }
    val modifiers = TerminalModifiers(ctrl = ctrl != ModifierState.OFF, alt = alt != ModifierState.OFF)
    val consumeModifiers = {
        if (ctrl == ModifierState.ARMED) ctrl = ModifierState.OFF
        if (alt == ModifierState.ARMED) alt = ModifierState.OFF
    }
    val ready = connected && snapshot != null
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusPill(stringResource(if (connected) R.string.terminal_live else R.string.terminal_offline), if (connected) PillTone.Live else PillTone.Idle)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onReconnect, enabled = (connected || error != null) && !reconnecting) {
                if (reconnecting) LoadingIndicator(Modifier.size(20.dp), color = Brand.Cyan)
                else Icon(Icons.Rounded.Sync, stringResource(R.string.terminal_reconnect), tint = Brand.Muted)
            }
            if (snapshot != null) IconButton(onClick = { viewMode = viewMode.next }) {
                // The icon announces the mode the tap switches to.
                Icon(
                    when (viewMode) { ViewMode.FIT -> Icons.Rounded.ZoomIn; ViewMode.WRAP -> Icons.Rounded.OpenInFull; ViewMode.PAN -> Icons.Rounded.ZoomOutMap },
                    stringResource(when (viewMode) { ViewMode.FIT -> R.string.screen_actual_size; ViewMode.WRAP -> R.string.screen_pan; ViewMode.PAN -> R.string.screen_fit_width }),
                    tint = Brand.Muted,
                )
            }
            IconButton(onClick = onRefresh, enabled = !loading) {
                if (loading) LoadingIndicator(Modifier.size(20.dp), color = Brand.Cyan)
                else Icon(Icons.Rounded.Refresh, stringResource(R.string.screen_refresh), tint = Brand.Muted)
            }
        }
        error?.let {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 6.dp)) {
                Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                errorDetail?.let { detail -> Text(stringResource(R.string.host_error_code, detail), color = Brand.Muted, style = MaterialTheme.typography.labelSmall) }
            }
        }
        val frameShape = RoundedCornerShape(20.dp)
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp)
                .clip(frameShape)
                .background(Color(parseColor(snapshot?.background, 0xFF070D20.toInt())))
                .border(1.dp, Brush.verticalGradient(listOf(Brand.GlassTop, Brand.GlassBottom)), frameShape),
        ) {
            if (snapshot == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    if (loading) LoadingIndicator(color = Brand.Cyan)
                    Text(stringResource(if (loading) R.string.screen_loading else R.string.screen_unavailable), Modifier.padding(top = 16.dp), color = Brand.Muted, style = MaterialTheme.typography.bodyMedium)
                }
            } else BoxWithConstraints(Modifier.fillMaxSize()) {
                val viewport = IntSize(constraints.maxWidth, constraints.maxHeight)
                val metrics = rememberTerminalMetrics(snapshot, if (viewMode == ViewMode.FIT) viewport else null)
                val scroll by rememberUpdatedState(onScroll)
                when (viewMode) {
                    ViewMode.WRAP -> {
                        // Readable size; long desktop rows wrap at the inner width instead of scrolling sideways.
                        val wrapColumns = ((viewport.width - 16f) / metrics.cellWidth).toInt().coerceAtLeast(8)
                        Box(Modifier.verticalScroll(rememberScrollState())) { TerminalGrid(snapshot, metrics, wrapColumns.takeIf { it < snapshot.columns }) }
                    }
                    ViewMode.PAN -> Box(Modifier.horizontalScroll(rememberScrollState()).verticalScroll(rememberScrollState())) { TerminalGrid(snapshot, metrics) }
                    ViewMode.FIT -> Box(
                    Modifier.fillMaxSize()
                        .semantics { contentDescription = "" }
                        .pointerInput(metrics.lineHeight, connected) {
                            if (!connected) return@pointerInput
                            var accumulated = 0f
                            detectVerticalDragGestures(onDragEnd = { accumulated = 0f }, onDragCancel = { accumulated = 0f }) { change, dragAmount ->
                                change.consume()
                                accumulated += dragAmount
                                val lines = (accumulated / metrics.lineHeight).toInt()
                                if (lines != 0) {
                                    accumulated -= lines * metrics.lineHeight
                                    // Finger down reveals older lines: scroll the desktop viewport up.
                                    scroll(-lines)
                                }
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) { TerminalGrid(snapshot, metrics) }
                }
            }
        }
        if (keysVisible) TerminalExtraKeys(
            ctrl = ctrl, alt = alt, onCtrl = { ctrl = it }, onAlt = { alt = it }, enabled = ready && !sending,
            onKey = { key -> onSend(TerminalKeyEncoder.encode(key, modifiers)) {}; consumeModifiers() },
            onText = { text -> onSend(TerminalKeyEncoder.encodeText(text, modifiers)) {}; consumeModifiers() },
        )
        TerminalComposer(
            enabled = ready, sending = sending, modifiers = modifiers, keysVisible = keysVisible,
            onToggleKeys = { keysVisible = !keysVisible },
            onSend = { text, onDelivered -> onSend(text, onDelivered); consumeModifiers() },
        )
    }
}

/** How the desktop grid is shown on the phone; none of these change the desktop PTY size. */
enum class ViewMode {
    /** Whole desktop screen scaled down; vertical drag scrolls the desktop scrollback. */
    FIT,
    /** Readable font, rows wrapped at the inner width, local vertical scroll. */
    WRAP,
    /** Readable font at true geometry with local horizontal and vertical panning. */
    PAN;

    val next: ViewMode get() = entries[(ordinal + 1) % entries.size]
}

/** Reading geometry for this device. The desktop PTY keeps its own columns and rows. */
private class TerminalMetrics(val fontSize: Float, val cellWidth: Float, val lineHeight: Float, val columns: Int, val rows: Int) {
    val widthPx: Float get() = columns * cellWidth + 16f
    val heightPx: Float get() = rows * lineHeight + 16f
}

@Composable
private fun rememberTerminalMetrics(snapshot: TerminalSnapshot, fit: IntSize?): TerminalMetrics {
    val density = LocalDensity.current
    val normalFontSize = with(density) { 13.sp.toPx() }
    return remember(snapshot.columns, snapshot.rows, fit, normalFontSize) {
        val normalCell = Paint().apply { textSize = normalFontSize; typeface = Typeface.MONOSPACE }.measureText("M")
        val normalLine = normalFontSize * 1.35f
        val scale = if (fit == null) 1f else minOf(
            (fit.width - 16f).coerceAtLeast(1f) / (snapshot.columns * normalCell),
            (fit.height - 16f).coerceAtLeast(1f) / (snapshot.rows * normalLine),
            1f,
        )
        val fontSize = normalFontSize * scale
        val cell = Paint().apply { textSize = fontSize; typeface = Typeface.MONOSPACE }.measureText("M")
        TerminalMetrics(fontSize, cell, fontSize * 1.35f, snapshot.columns, snapshot.rows)
    }
}

/**
 * Draws the desktop grid. With [wrapColumns] every desktop row is folded into
 * `ceil(columns / wrapColumns)` visual lines so nothing is cut off at the phone's width.
 */
@Composable
private fun TerminalGrid(snapshot: TerminalSnapshot, metrics: TerminalMetrics, wrapColumns: Int? = null) {
    val density = LocalDensity.current
    val paint = remember(metrics.fontSize) { Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = metrics.fontSize; typeface = Typeface.MONOSPACE } }
    val typefaces = remember { listOf(Typeface.NORMAL, Typeface.BOLD, Typeface.ITALIC, Typeface.BOLD_ITALIC).associateWith { Typeface.create(Typeface.MONOSPACE, it) } }
    val cellWidth = metrics.cellWidth
    val lineHeight = metrics.lineHeight
    val wrap = wrapColumns ?: snapshot.columns
    val linesPerRow = (snapshot.columns + wrap - 1) / wrap
    val width = with(density) { (wrap * cellWidth + 16f).toDp() }
    val height = with(density) { (snapshot.rows * linesPerRow * lineHeight + 16f).toDp() }
    val defaultForeground = parseColor(snapshot.foreground, android.graphics.Color.rgb(238, 243, 255))
    val defaultBackground = parseColor(snapshot.background, android.graphics.Color.rgb(7, 13, 32))
    // Cell → pixel origin, folding wide rows when wrapping.
    fun originX(column: Int) = 8 + (column % wrap) * cellWidth
    fun originY(row: Int, column: Int) = 8 + (row * linesPerRow + column / wrap) * lineHeight
    Canvas(Modifier.requiredSize(width, height)) {
        drawIntoCanvas { target ->
            val canvas = target.nativeCanvas
            canvas.drawColor(defaultBackground)
            snapshot.spans.forEach { span ->
                val style = span.style
                var foreground = parseColor(style.foreground, defaultForeground)
                var background = parseColor(style.background, defaultBackground)
                if (style.inverse) { val old = foreground; foreground = background; background = old }
                paint.typeface = typefaces[when {
                    style.bold && style.italic -> Typeface.BOLD_ITALIC
                    style.bold -> Typeface.BOLD
                    style.italic -> Typeface.ITALIC
                    else -> Typeface.NORMAL
                }]
                paint.isUnderlineText = style.underline
                paint.isStrikeThruText = style.strikethrough
                val baseline = lineHeight - paint.fontMetrics.descent
                // A span stays one draw call unless wrapping splits it across visual lines.
                val pieces: List<Triple<Int, String, Int>> = if (wrapColumns == null || span.column / wrap == (span.column + span.cellWidth - 1) / wrap) {
                    listOf(Triple(span.column, span.text, span.cellWidth))
                } else {
                    val unit = if (span.text.isEmpty()) 1 else (span.cellWidth / span.text.length).coerceAtLeast(1)
                    span.text.mapIndexed { index, char -> Triple(span.column + index * unit, char.toString(), unit) }
                }
                pieces.forEach { (column, text, cells) ->
                    val x = originX(column)
                    val y = originY(span.row, column)
                    paint.style = Paint.Style.FILL
                    paint.color = background
                    canvas.drawRect(x, y, x + cells * cellWidth, y + lineHeight, paint)
                    if (!style.invisible) {
                        paint.color = foreground
                        paint.alpha = if (style.faint) 150 else 255
                        canvas.drawText(text, x, y + baseline, paint)
                        if (style.overline) canvas.drawRect(x, y + 1, x + cells * cellWidth, y + 2, paint)
                        paint.alpha = 255
                    }
                }
            }
            snapshot.cursor?.takeIf { it.visible && it.row in 0 until snapshot.rows && it.column in 0 until snapshot.columns }?.let { cursor ->
                paint.isUnderlineText = false
                paint.isStrikeThruText = false
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.5f
                paint.color = defaultForeground
                val x = originX(cursor.column)
                val y = originY(cursor.row, cursor.column)
                canvas.drawRect(x, y, x + cellWidth, y + lineHeight, paint)
                paint.style = Paint.Style.FILL
            }
        }
    }
}

private fun parseColor(value: String?, fallback: Int): Int {
    if (value == null || !Regex("#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?").matches(value)) return fallback
    return runCatching { android.graphics.Color.parseColor(value) }.getOrDefault(fallback)
}
