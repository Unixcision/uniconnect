package com.unixcision.uniconnect.android.ui

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.LinkOff
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
import androidx.compose.ui.platform.LocalConfiguration
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
    onSend: (String, Boolean, (Boolean) -> Unit) -> Unit,
    real: MachinesViewModel.RealTerminal? = null,
    attachUnsupported: Boolean = false,
    onStartReal: (Int, Int, Boolean) -> Unit = { _, _, _ -> },
    onStopReal: () -> Unit = {},
    onPty: (String, Boolean) -> Unit = { _, _ -> },
    onPtyWheel: (Boolean, Int) -> Unit = { _, _ -> },
    onPtyResize: (Int, Int) -> Unit = { _, _ -> },
) {
    var realRequested by rememberSaveable { mutableStateOf(false) }
    // Default way in: attach to the window's own tmux session. Only a host without the attach RPC,
    // or leaving the mode by hand, falls back to the mirrored screen.
    var autoTried by rememberSaveable { mutableStateOf(false) }
    var manuallyLeft by rememberSaveable { mutableStateOf(false) }
    if (real != null) {
        RealTerminalScreen(real, connected, sending, onStopReal = { realRequested = false; manuallyLeft = true; onStopReal() }, onPty = onPty, onPtyWheel = onPtyWheel, onPtyResize = onPtyResize)
        return
    }
    if (realRequested) realRequested = false
    if (!autoTried && !manuallyLeft && !attachUnsupported && connected) {
        RealTerminalStarter(true) { columns, rows -> autoTried = true; onStartReal(columns, rows, true) }
    }
    MirrorTerminalScreen(snapshot, loading, error, errorDetail, sending, reconnecting, connected, onRefresh, onReconnect, onScroll, onSend,
        onRequestReal = { columns, rows -> realRequested = true; manuallyLeft = false; onStartReal(columns, rows, false) })
}

/** The attached tmux client: the phone owns a real PTY of its own size; tmux keeps the desktop's. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun RealTerminalScreen(
    real: MachinesViewModel.RealTerminal, connected: Boolean, sending: Boolean,
    onStopReal: () -> Unit, onPty: (String, Boolean) -> Unit, onPtyWheel: (Boolean, Int) -> Unit, onPtyResize: (Int, Int) -> Unit,
) {
    var keysVisible by rememberSaveable { mutableStateOf(false) }
    var ctrl by rememberSaveable { mutableStateOf(ModifierState.OFF) }
    var alt by rememberSaveable { mutableStateOf(ModifierState.OFF) }
    val modifiers = TerminalModifiers(ctrl = ctrl != ModifierState.OFF, alt = alt != ModifierState.OFF)
    val consumeModifiers = {
        if (ctrl == ModifierState.ARMED) ctrl = ModifierState.OFF
        if (alt == ModifierState.ARMED) alt = ModifierState.OFF
    }
    val ready = real.snapshot != null && !real.ended && real.error == null
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusPill(stringResource(R.string.real_terminal_pill), if (ready) PillTone.Busy else PillTone.Idle)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onStopReal) { Icon(Icons.Rounded.LinkOff, stringResource(R.string.real_terminal_stop), tint = Brand.Muted) }
        }
        real.error?.let {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 6.dp)) {
                Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                real.errorDetail?.let { detail -> Text(stringResource(R.string.host_error_code, detail), color = Brand.Muted, style = MaterialTheme.typography.labelSmall) }
            }
        }
        if (real.ended) Text(stringResource(R.string.real_terminal_ended), Modifier.padding(horizontal = 20.dp, vertical = 6.dp), color = Brand.Amber, style = MaterialTheme.typography.bodySmall)
        val frameShape = RoundedCornerShape(20.dp)
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp).clip(frameShape)
                .background(Color(parseColor(real.snapshot?.background, 0xFF070D20.toInt())))
                .border(1.dp, Brush.verticalGradient(listOf(Brand.GlassTop, Brand.GlassBottom)), frameShape),
        ) {
            val snapshot = real.snapshot
            if (snapshot == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    if (real.connecting) {
                        LoadingIndicator(color = Brand.Cyan)
                        Text(stringResource(R.string.real_terminal_connecting), Modifier.padding(top = 16.dp), color = Brand.Muted, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            } else BoxWithConstraints(Modifier.fillMaxSize()) {
                val metrics = rememberTerminalMetrics(snapshot, null)
                val columns = ((constraints.maxWidth - 16f) / metrics.cellWidth).toInt().coerceIn(10, 500)
                val rows = ((constraints.maxHeight - 16f) / metrics.lineHeight).toInt().coerceIn(3, 200)
                // Keyboard or rotation changed the viewport: the phone's own client follows, tmux keeps the desktop.
                LaunchedEffect(columns, rows) { if (columns != snapshot.columns || rows != snapshot.rows) onPtyResize(columns, rows) }
                val wheel by rememberUpdatedState(onPtyWheel)
                Box(
                    Modifier.fillMaxSize().pointerInput(metrics.lineHeight) {
                        var accumulated = 0f
                        detectVerticalDragGestures(onDragEnd = { accumulated = 0f }, onDragCancel = { accumulated = 0f }) { change, dragAmount ->
                            change.consume()
                            accumulated += dragAmount
                            val lines = (accumulated / metrics.lineHeight).toInt()
                            if (lines != 0) { accumulated -= lines * metrics.lineHeight; wheel(lines > 0, kotlin.math.abs(lines)) }
                        }
                    },
                    contentAlignment = Alignment.TopStart,
                ) { TerminalGrid(snapshot, metrics) }
            }
        }
        if (keysVisible) TerminalExtraKeys(
            ctrl = ctrl, alt = alt, onCtrl = { ctrl = it }, onAlt = { alt = it }, enabled = ready && connected,
            onKey = { key -> onPty(TerminalKeyEncoder.encode(key, modifiers, cursorApplicationMode = real.applicationCursorKeys), false); consumeModifiers() },
            onText = { text -> onPty(TerminalKeyEncoder.encodeText(text, modifiers), false); consumeModifiers() },
        )
        TerminalComposer(
            enabled = ready && connected, sending = sending, modifiers = modifiers, keysVisible = keysVisible,
            onToggleKeys = { keysVisible = !keysVisible },
            onSend = { text, withEnter, onDelivered -> onPty(text, withEnter); onDelivered(true); consumeModifiers() },
        )
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun MirrorTerminalScreen(
    snapshot: TerminalSnapshot?, loading: Boolean, error: Int?, errorDetail: String?, sending: Boolean, reconnecting: Boolean, connected: Boolean,
    onRefresh: () -> Unit, onReconnect: () -> Unit, onScroll: (Int) -> Unit, onSend: (String, Boolean, (Boolean) -> Unit) -> Unit,
    onRequestReal: (Int, Int) -> Unit,
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
            // Real terminal: a tmux client of the phone's size. The readable geometry is measured
            // here so the attach asks the host for exactly the size this screen can draw.
            var armReal by remember { mutableStateOf(false) }
            IconButton(onClick = { armReal = true }, enabled = connected) {
                Icon(Icons.Rounded.Link, stringResource(R.string.real_terminal_start), tint = Brand.Muted)
            }
            RealTerminalStarter(armReal) { columns, rows -> armReal = false; onRequestReal(columns, rows) }
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
                // Captured here: the nested scroll boxes are outside BoxWithConstraints' scope.
                val viewportHeight = viewport.height
                val metrics = rememberTerminalMetrics(snapshot, if (viewMode == ViewMode.FIT) viewport else null)
                val scroll by rememberUpdatedState(onScroll)
                val history = snapshot.scrollbackRows > 0
                when {
                    // With exported history the whole canvas scrolls locally, newest lines at the bottom.
                    viewMode == ViewMode.FIT && history -> {
                        val scrollState = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.fillMaxSize().verticalScroll(scrollState), contentAlignment = Alignment.TopCenter) {
                            TerminalGrid(snapshot, metrics, scroll = scrollState, viewportHeightPx = viewportHeight)
                        }
                    }
                    viewMode == ViewMode.WRAP -> {
                        // Readable size; long desktop rows wrap at the inner width instead of scrolling sideways.
                        val wrapColumns = ((viewport.width - 16f) / metrics.cellWidth).toInt().coerceAtLeast(8)
                        val wrapScroll = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.verticalScroll(wrapScroll)) {
                            TerminalGrid(snapshot, metrics, wrapColumns.takeIf { it < snapshot.columns }, scroll = wrapScroll, viewportHeightPx = viewportHeight)
                        }
                    }
                    viewMode == ViewMode.PAN -> {
                        val panScroll = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.horizontalScroll(rememberScrollState()).verticalScroll(panScroll)) {
                            TerminalGrid(snapshot, metrics, scroll = panScroll, viewportHeightPx = viewportHeight)
                        }
                    }
                    else -> Box(
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
            onKey = { key -> onSend(TerminalKeyEncoder.encode(key, modifiers), false) {}; consumeModifiers() },
            onText = { text -> onSend(TerminalKeyEncoder.encodeText(text, modifiers), false) {}; consumeModifiers() },
        )
        TerminalComposer(
            enabled = ready, sending = sending, modifiers = modifiers, keysVisible = keysVisible,
            onToggleKeys = { keysVisible = !keysVisible },
            onSend = { text, withEnter, onDelivered -> onSend(text, withEnter, onDelivered); consumeModifiers() },
        )
    }
}

/**
 * Vertical scroll that opens on the live screen (bottom) and follows new output while the user
 * is at the bottom; history above stays reachable by pulling down, never shown first.
 */
@Composable
private fun rememberPinnedScrollState(snapshot: TerminalSnapshot, lineHeight: Float): ScrollState {
    val scrollState = rememberScrollState(Int.MAX_VALUE)
    // Sticky by default: the live screen is what you see when you open a window, however much
    // history the host exported. Reading history is an explicit drag, and releasing at the
    // bottom sticks again. Without this a big history dump left the view on the oldest lines.
    var stick by remember { mutableStateOf(true) }
    LaunchedEffect(scrollState) {
        snapshotFlow { scrollState.isScrollInProgress }.collect { scrolling ->
            if (!scrolling) stick = scrollState.value >= scrollState.maxValue - (lineHeight * 2).toInt()
        }
    }
    LaunchedEffect(snapshot, scrollState.maxValue) {
        if (stick && !scrollState.isScrollInProgress && scrollState.maxValue > 0) scrollState.scrollTo(scrollState.maxValue)
    }
    return scrollState
}

/** Measures the phone's readable geometry once the user asks for the real terminal, then starts it. */
@Composable
private fun RealTerminalStarter(armed: Boolean, onStart: (Int, Int) -> Unit) {
    if (!armed) return
    val density = LocalDensity.current
    val configuration = LocalConfiguration.current
    LaunchedEffect(armed) {
        val fontSize = with(density) { 13.sp.toPx() }
        val cell = Paint().apply { textSize = fontSize; typeface = Typeface.MONOSPACE }.measureText("M")
        val widthPx = with(density) { configuration.screenWidthDp.dp.toPx() } - 36f
        val heightPx = with(density) { configuration.screenHeightDp.dp.toPx() } * 0.55f
        onStart((widthPx / cell).toInt().coerceIn(20, 500), (heightPx / (fontSize * 1.35f)).toInt().coerceIn(8, 200))
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
private fun TerminalGrid(
    snapshot: TerminalSnapshot,
    metrics: TerminalMetrics,
    wrapColumns: Int? = null,
    scroll: ScrollState? = null,
    viewportHeightPx: Int = 0,
) {
    val density = LocalDensity.current
    val paint = remember(metrics.fontSize) { Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = metrics.fontSize; typeface = Typeface.MONOSPACE } }
    val typefaces = remember { listOf(Typeface.NORMAL, Typeface.BOLD, Typeface.ITALIC, Typeface.BOLD_ITALIC).associateWith { Typeface.create(Typeface.MONOSPACE, it) } }
    val cellWidth = metrics.cellWidth
    val lineHeight = metrics.lineHeight
    val wrap = wrapColumns ?: snapshot.columns
    val linesPerRow = (snapshot.columns + wrap - 1) / wrap
    val history = snapshot.scrollbackRows
    val width = with(density) { (wrap * cellWidth + 16f).toDp() }
    val height = with(density) { ((history + snapshot.rows) * linesPerRow * lineHeight + 16f).toDp() }
    val defaultForeground = parseColor(snapshot.foreground, android.graphics.Color.rgb(238, 243, 255))
    val defaultBackground = parseColor(snapshot.background, android.graphics.Color.rgb(7, 13, 32))
    // History rows are indexed once per replay: a delta keeps the same list, so typing never
    // rebuilds it. Thousands of exported lines must not cost anything until they scroll into view.
    val historyByRow = remember(snapshot.scrollbackSpans, history) {
        val index = HashMap<Int, MutableList<TerminalSnapshot.Span>>(minOf(history, 4096))
        snapshot.scrollbackSpans.forEach { span ->
            if (span.row in 0 until history) index.getOrPut(span.row) { ArrayList(4) }.add(span)
        }
        index
    }
    // Cell → pixel origin, folding wide rows when wrapping.
    fun originX(column: Int) = 8 + (column % wrap) * cellWidth
    fun originY(row: Int, column: Int) = 8 + (row * linesPerRow + column / wrap) * lineHeight
    Canvas(Modifier.requiredSize(width, height)) {
        drawIntoCanvas { target ->
            val canvas = target.nativeCanvas
            canvas.drawColor(defaultBackground)
            // Only the rows the viewport can show are drawn; the canvas keeps its full height so
            // scrolling still spans the whole history.
            val rowHeight = lineHeight * linesPerRow
            val offset = scroll?.value ?: 0
            val viewport = if (viewportHeightPx > 0) viewportHeightPx else size.height.toInt()
            val firstRow = if (scroll == null) 0 else (((offset - 8) / rowHeight).toInt() - 1).coerceAtLeast(0)
            val lastRow = if (scroll == null) history + snapshot.rows - 1
                else (((offset + viewport - 8) / rowHeight).toInt() + 1).coerceAtMost(history + snapshot.rows - 1)
            val drawable = sequence {
                for (row in firstRow..lastRow) {
                    if (row < history) historyByRow[row]?.forEach { yield(it to row) }
                    else snapshot.spans.forEach { if (it.row == row - history) yield(it to row) }
                }
            }
            drawable.forEach { (span, drawRow) ->
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
                    val y = originY(drawRow, column)
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
                val y = originY(cursor.row + history, cursor.column)
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
