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
    var fitScreen by rememberSaveable { mutableStateOf(true) }
    var keysVisible by rememberSaveable { mutableStateOf(true) }
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
            if (snapshot != null) IconButton(onClick = { fitScreen = !fitScreen }) {
                Icon(if (fitScreen) Icons.Rounded.ZoomIn else Icons.Rounded.ZoomOutMap,
                    stringResource(if (fitScreen) R.string.screen_actual_size else R.string.screen_fit_width), tint = Brand.Muted)
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
                val metrics = rememberTerminalMetrics(snapshot, if (fitScreen) viewport else null)
                val scroll by rememberUpdatedState(onScroll)
                if (fitScreen) Box(
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
                else Box(Modifier.horizontalScroll(rememberScrollState()).verticalScroll(rememberScrollState())) { TerminalGrid(snapshot, metrics) }
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

@Composable
private fun TerminalGrid(snapshot: TerminalSnapshot, metrics: TerminalMetrics) {
    val density = LocalDensity.current
    val paint = remember(metrics.fontSize) { Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = metrics.fontSize; typeface = Typeface.MONOSPACE } }
    val typefaces = remember { listOf(Typeface.NORMAL, Typeface.BOLD, Typeface.ITALIC, Typeface.BOLD_ITALIC).associateWith { Typeface.create(Typeface.MONOSPACE, it) } }
    val cellWidth = metrics.cellWidth
    val lineHeight = metrics.lineHeight
    val width = with(density) { metrics.widthPx.toDp() }
    val height = with(density) { metrics.heightPx.toDp() }
    val defaultForeground = parseColor(snapshot.foreground, android.graphics.Color.rgb(238, 243, 255))
    val defaultBackground = parseColor(snapshot.background, android.graphics.Color.rgb(7, 13, 32))
    Canvas(Modifier.requiredSize(width, height)) {
        drawIntoCanvas { target ->
            val canvas = target.nativeCanvas
            canvas.drawColor(defaultBackground)
            snapshot.spans.forEach { span ->
                val style = span.style
                var foreground = parseColor(style.foreground, defaultForeground)
                var background = parseColor(style.background, defaultBackground)
                if (style.inverse) { val old = foreground; foreground = background; background = old }
                val x = 8 + span.column * cellWidth
                val y = 8 + span.row * lineHeight
                paint.style = Paint.Style.FILL
                paint.color = background
                canvas.drawRect(x, y, x + span.cellWidth * cellWidth, y + lineHeight, paint)
                if (!style.invisible) {
                    paint.color = foreground
                    paint.typeface = typefaces[when {
                        style.bold && style.italic -> Typeface.BOLD_ITALIC
                        style.bold -> Typeface.BOLD
                        style.italic -> Typeface.ITALIC
                        else -> Typeface.NORMAL
                    }]
                    paint.isUnderlineText = style.underline
                    paint.isStrikeThruText = style.strikethrough
                    paint.alpha = if (style.faint) 150 else 255
                    canvas.drawText(span.text, x, y + lineHeight - paint.fontMetrics.descent, paint)
                    if (style.overline) canvas.drawRect(x, y + 1, x + span.cellWidth * cellWidth, y + 2, paint)
                    paint.alpha = 255
                }
            }
            snapshot.cursor?.takeIf { it.visible && it.row in 0 until snapshot.rows && it.column in 0 until snapshot.columns }?.let { cursor ->
                paint.isUnderlineText = false
                paint.isStrikeThruText = false
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.5f
                paint.color = defaultForeground
                val x = 8 + cursor.column * cellWidth
                val y = 8 + cursor.row * lineHeight
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
