package com.unixcision.uniconnect.android.ui

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.ZoomIn
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.TerminalSnapshot

@Composable
fun TerminalScreen(snapshot: TerminalSnapshot?, loading: Boolean, error: Int?, sending: Boolean, connected: Boolean, onRefresh: () -> Unit, onSend: (String, (Boolean) -> Unit) -> Unit) {
    var fitWidth by rememberSaveable { mutableStateOf(true) }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(if (connected) R.string.terminal_live else R.string.terminal_offline), style = MaterialTheme.typography.labelMedium, color = if (connected) Brand.Cyan else Brand.Muted)
            Spacer(Modifier.weight(1f))
            if (snapshot != null) IconButton(onClick = { fitWidth = !fitWidth }) {
                Icon(if (fitWidth) Icons.Rounded.ZoomIn else Icons.Rounded.ZoomOutMap,
                    stringResource(if (fitWidth) R.string.screen_actual_size else R.string.screen_fit_width), tint = Brand.Muted)
            }
            IconButton(onClick = onRefresh, enabled = !loading) {
                if (loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else Icon(Icons.Rounded.Refresh, stringResource(R.string.screen_refresh), tint = Brand.Muted)
            }
        }
        error?.let { Text(stringResource(it), Modifier.padding(horizontal = 20.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.error) }
        if (snapshot == null) {
            Box(Modifier.weight(1f).padding(24.dp)) { Text(stringResource(if (loading) R.string.screen_loading else R.string.screen_unavailable), color = Brand.Muted) }
        } else {
            Surface(Modifier.weight(1f).fillMaxWidth(), color = androidx.compose.ui.graphics.Color(parseColor(snapshot.background, 0xFF070D20.toInt()))) {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val availableWidth = constraints.maxWidth.toFloat()
                    Box(Modifier.horizontalScroll(rememberScrollState()).verticalScroll(rememberScrollState())) {
                        TerminalGrid(snapshot, if (fitWidth) availableWidth else null)
                    }
                }
            }
        }
        TerminalComposer(connected && snapshot != null, sending, onSend)
    }
}

@Composable
private fun TerminalGrid(snapshot: TerminalSnapshot, fitWidthPx: Float?) {
    val density = LocalDensity.current
    val normalFontSize = with(density) { 13.sp.toPx() }
    val normalCellWidth = remember(normalFontSize) {
        Paint().apply { textSize = normalFontSize; typeface = Typeface.MONOSPACE }.measureText("M")
    }
    // Reading scale belongs to this device; never resize the desktop PTY just to fit a phone.
    val scale = fitWidthPx?.let { ((it - 16).coerceAtLeast(1f) / (snapshot.columns * normalCellWidth)).coerceAtMost(1f) } ?: 1f
    val fontSize = normalFontSize * scale
    val paint = remember(fontSize) { Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = fontSize; typeface = Typeface.MONOSPACE } }
    val typefaces = remember { listOf(Typeface.NORMAL, Typeface.BOLD, Typeface.ITALIC, Typeface.BOLD_ITALIC).associateWith { Typeface.create(Typeface.MONOSPACE, it) } }
    val cellWidth = paint.measureText("M")
    val lineHeight = fontSize * 1.35f
    val width = with(density) { (snapshot.columns * cellWidth + 16).toDp() }
    val height = with(density) { (snapshot.rows * lineHeight + 16).toDp() }
    val defaultForeground = parseColor(snapshot.foreground, android.graphics.Color.rgb(238, 243, 255))
    val defaultBackground = parseColor(snapshot.background, android.graphics.Color.rgb(7, 13, 32))
    Canvas(Modifier.requiredSize(width, height)) {
        drawIntoCanvas { target ->
            val canvas = target.nativeCanvas
            canvas.drawColor(defaultBackground)
            snapshot.spans.forEach { span ->
                val style = span.style
                var foreground = parseColor(style?.foreground, defaultForeground)
                var background = parseColor(style?.background, defaultBackground)
                if (style?.inverse == true) { val old = foreground; foreground = background; background = old }
                val x = 8 + span.column * cellWidth
                val y = 8 + span.row * lineHeight
                paint.style = Paint.Style.FILL
                paint.color = background
                canvas.drawRect(x, y, x + span.cellWidth * cellWidth, y + lineHeight, paint)
                if (style?.invisible != true) {
                    paint.color = foreground
                    paint.typeface = typefaces[when {
                        style?.bold == true && style.italic -> Typeface.BOLD_ITALIC
                        style?.bold == true -> Typeface.BOLD
                        style?.italic == true -> Typeface.ITALIC
                        else -> Typeface.NORMAL
                    }]
                    paint.isUnderlineText = style?.underline == true
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
