package com.unixcision.uniconnect.android.ui

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloseFullscreen
import androidx.compose.material.icons.rounded.KeyboardDoubleArrowDown
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.ZoomIn
import androidx.compose.material.icons.rounded.ZoomOutMap
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.Velocity
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
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.TerminalKeyEncoder
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.domain.TerminalModifiers
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import com.unixcision.uniconnect.android.ui.components.ActivityMark
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
    attachFallbackDetail: String? = null,
    onStartReal: (Int, Int, Boolean) -> Unit = { _, _, _ -> },
    onStopReal: () -> Unit = {},
    onPty: (String, Boolean) -> Unit = { _, _ -> },
    onPtyWheel: (Boolean, Int) -> Unit = { _, _ -> },
    onPtyResize: (Int, Int) -> Unit = { _, _ -> },
    onLeaveCopyMode: () -> Unit = {},
    settings: AppSettings = AppSettings(),
    resumeReal: Boolean = false,
    view: TerminalView? = null,
    zoom: Float = 1f,
    onView: (TerminalView) -> Unit = {},
    onZoom: (Float) -> Unit = {},
    onReconnectReal: () -> Unit = {},
    draft: String = "",
    onDraftChange: (String) -> Unit = {},
    windowPinned: Boolean = false,
    onTogglePin: () -> Unit = {},
    activity: ActivityState = ActivityState.UNKNOWN,
    attachments: AttachViewModel? = null,
    attachTarget: AttachTarget? = null,
    dictation: DictationViewModel? = null,
) {
    var realRequested by rememberSaveable { mutableStateOf(false) }
    // Default way in: attach to the window's own tmux session. Only a host without the attach RPC,
    // or leaving the mode by hand, falls back to the mirrored screen.
    var autoTried by rememberSaveable { mutableStateOf(false) }
    var manuallyLeft by rememberSaveable { mutableStateOf(false) }
    if (real != null) {
        RealTerminalScreen(
            real, connected, sending, view ?: settings.terminalView, zoom, settings.showExtraKeys,
            onStopReal = { realRequested = false; manuallyLeft = true; onStopReal() },
            onPty = onPty, onPtyWheel = onPtyWheel, onPtyResize = onPtyResize,
            onLeaveCopyMode = onLeaveCopyMode, onView = onView, onZoom = onZoom, onReconnect = onReconnectReal,
            draft = draft, onDraftChange = onDraftChange, windowPinned = windowPinned, onTogglePin = onTogglePin, activity = activity,
            attachments = attachments, attachTarget = attachTarget, dictation = dictation, settings = settings,
        )
        return
    }
    if (realRequested) realRequested = false
    // `resumeReal` says the app itself closed the attachment on the way to the background, so
    // trying once is not the whole story: the reader never asked to be in the mirror.
    if ((!autoTried || resumeReal) && !manuallyLeft && !attachUnsupported && connected) {
        RealTerminalStarter(true) { columns, rows -> autoTried = true; onStartReal(columns, rows, true) }
    }
    MirrorTerminalScreen(snapshot, loading, error, errorDetail, sending, reconnecting, connected, onRefresh, onReconnect, onScroll, onSend,
        attachFallbackDetail = attachFallbackDetail,
        onRequestReal = { columns, rows -> realRequested = true; manuallyLeft = false; onStartReal(columns, rows, false) },
        draft = draft, onDraftChange = onDraftChange, windowPinned = windowPinned, onTogglePin = onTogglePin, activity = activity,
        attachments = attachments, attachTarget = attachTarget, dictation = dictation, settings = settings)
}

/** The attached tmux client: the phone owns a real PTY of its own size; tmux keeps the desktop's. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun RealTerminalScreen(
    real: MachinesViewModel.RealTerminal, connected: Boolean, sending: Boolean,
    viewMode: TerminalView, zoom: Float, startWithKeys: Boolean,
    onStopReal: () -> Unit, onPty: (String, Boolean) -> Unit, onPtyWheel: (Boolean, Int) -> Unit, onPtyResize: (Int, Int) -> Unit,
    onLeaveCopyMode: () -> Unit, onView: (TerminalView) -> Unit, onZoom: (Float) -> Unit, onReconnect: () -> Unit,
    draft: String, onDraftChange: (String) -> Unit, windowPinned: Boolean, onTogglePin: () -> Unit, activity: ActivityState,
    attachments: AttachViewModel?, attachTarget: AttachTarget?, dictation: DictationViewModel?, settings: AppSettings,
) {
    var keysVisible by rememberSaveable { mutableStateOf(startWithKeys) }
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
            ActivityMark(activity, Modifier.padding(start = 10.dp), size = 18.dp)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onTogglePin) {
                Icon(if (windowPinned) Icons.Rounded.Star else Icons.Rounded.StarBorder, stringResource(if (windowPinned) R.string.box_unpin else R.string.box_pin), tint = if (windowPinned) UniTheme.colors.warning else UniTheme.colors.muted)
            }
            // The clip: attach to this window, and paste the path or link into the composer.
            if (attachments != null && attachTarget != null) AttachButton(attachments, attachTarget, draft, onDraftChange)
            // One tap back to the live screen, handled by the model: it walks the pane out with
            // wheel steps and stops as soon as tmux's indicator clears.
            if (real.copyMode) IconButton(onClick = onLeaveCopyMode) {
                Icon(Icons.Rounded.KeyboardDoubleArrowDown, stringResource(R.string.terminal_leave_copy_mode), tint = UniTheme.colors.warning)
            }
            if (real.snapshot != null) IconButton(onClick = { onView(viewMode.next) }) {
                Icon(
                    when (viewMode) { TerminalView.FIT -> Icons.Rounded.ZoomIn; TerminalView.WRAP -> Icons.Rounded.OpenInFull; TerminalView.PAN -> Icons.Rounded.ZoomOutMap },
                    stringResource(when (viewMode) { TerminalView.FIT -> R.string.screen_actual_size; TerminalView.WRAP -> R.string.screen_pan; TerminalView.PAN -> R.string.screen_fit_width }),
                    tint = UniTheme.colors.muted,
                )
            }
            IconButton(onClick = onStopReal) { Icon(Icons.Rounded.LinkOff, stringResource(R.string.real_terminal_stop), tint = UniTheme.colors.muted) }
        }
        real.error?.let {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 6.dp)) {
                Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                real.errorDetail?.let { detail -> Text(stringResource(R.string.host_error_code, detail), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall) }
            }
        }
        // The host ended or refused the session: say so and offer the way back in right here,
        // instead of leaving a greyed-out composer and a detour through the mirror.
        if (real.ended || real.error != null) Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (real.ended) Text(stringResource(R.string.real_terminal_ended), Modifier.weight(1f), color = UniTheme.colors.warning, style = MaterialTheme.typography.bodySmall)
            else Spacer(Modifier.weight(1f))
            Button(onClick = onReconnect, enabled = connected, shape = UniTheme.shapes.button, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
                Icon(Icons.Rounded.Refresh, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.real_terminal_reconnect))
            }
        }
        val frameShape = UniTheme.shapes.card
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp).clip(frameShape)
                .background(Color(parseColor(real.snapshot?.background, 0xFF070D20.toInt())))
                .border(1.dp, UniTheme.colors.outlineFade, frameShape),
        ) {
            val snapshot = real.snapshot
            if (snapshot == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    if (real.connecting) {
                        LoadingIndicator(color = UniTheme.colors.accent)
                        Text(stringResource(R.string.real_terminal_connecting), Modifier.padding(top = 16.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            } else BoxWithConstraints(Modifier.fillMaxSize()) {
                // The host keeps the desktop's geometry (tmux ignore-size), so FIT shows that
                // window scaled to the phone's width. Asking for the phone's own size only made
                // tmux pad the rows the desktop does not have with dots.
                val viewport = IntSize(constraints.maxWidth, constraints.maxHeight)
                val metrics = rememberTerminalMetrics(snapshot, viewport.takeIf { viewMode == TerminalView.FIT }, zoom)
                val wheel by rememberUpdatedState(onPtyWheel)
                // Two fingers are always the reader's: pinch resizes the text without ever
                // touching the shared window. One finger is left alone here so the scrolling
                // modes below still work; FIT consumes it itself to drive tmux.
                //
                // The gesture is installed once, so it reads the live zoom through these rather
                // than the value captured when it was built.
                val magnification by rememberUpdatedState(zoom)
                val setZoom by rememberUpdatedState(onZoom)
                val pinch = Modifier.pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        do {
                            val event = awaitPointerEvent()
                            if (event.changes.size >= 2) {
                                val change = event.calculateZoom()
                                if (change != 1f) {
                                    setZoom((magnification * change).coerceIn(MIN_ZOOM, MAX_ZOOM))
                                    event.changes.forEach { it.consume() }
                                }
                            }
                        } while (event.changes.any { it.pressed })
                    }
                }
                // Where a local canvas ends, the session begins: a drag past the top of the
                // wrapped or panned canvas becomes wheel steps, which is how tmux is asked for
                // its scrollback. Without this the zoomed readings could only show the last
                // screenful, and history was reachable from the fitted reading alone.
                val reachHistory = remember(metrics.lineHeight) {
                    object : NestedScrollConnection {
                        private var accumulated = 0f
                        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                            if (available.y == 0f) return Offset.Zero
                            // Only the finger drives tmux. Inertia arriving here frame after frame
                            // used to become hundreds of wheel steps that scrolled for many seconds
                            // after the finger was gone; it is swallowed below instead.
                            if (source != NestedScrollSource.UserInput) return Offset(0f, available.y)
                            accumulated += available.y
                            val lines = (accumulated / metrics.lineHeight).toInt()
                            if (lines != 0) {
                                accumulated -= lines * metrics.lineHeight
                                wheel(lines > 0, kotlin.math.abs(lines))
                            }
                            return Offset(0f, available.y)
                        }

                        override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                            // A flick past the edge asks tmux for a short, bounded run, not a second per
                            // pixel of velocity; then the fling is finished, whatever is left of it.
                            val lines = (available.y / metrics.lineHeight * FLING_SECONDS).toInt().coerceIn(-FLING_MAX_LINES, FLING_MAX_LINES)
                            if (lines != 0) wheel(lines > 0, kotlin.math.abs(lines))
                            return available
                        }
                    }
                }
                when (viewMode) {
                    // Fitted: one finger scrolls tmux itself, which is what makes this the session
                    // and not a picture of it.
                    TerminalView.FIT -> Box(
                        Modifier.fillMaxSize().then(pinch).pointerInput(metrics.lineHeight) {
                            awaitEachGesture {
                                awaitFirstDown(requireUnconsumed = false)
                                var accumulated = 0f
                                var multitouch = false
                                do {
                                    val event = awaitPointerEvent()
                                    if (event.changes.size >= 2) multitouch = true
                                    else if (!multitouch) {
                                        accumulated += event.calculatePan().y
                                        val lines = (accumulated / metrics.lineHeight).toInt()
                                        if (lines != 0) {
                                            accumulated -= lines * metrics.lineHeight
                                            wheel(lines > 0, kotlin.math.abs(lines))
                                        }
                                        event.changes.forEach { it.consume() }
                                    }
                                } while (event.changes.any { it.pressed })
                            }
                        },
                        contentAlignment = Alignment.Center,
                    ) { TerminalGrid(snapshot, metrics) }
                    // Readable size, long rows folded at the phone's width, local vertical scroll
                    // that continues into tmux's own history once it reaches its end.
                    TerminalView.WRAP -> {
                        val wrapColumns = ((viewport.width - 16f) / metrics.cellWidth).toInt().coerceAtLeast(8)
                        val wrapScroll = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.fillMaxSize().then(pinch).nestedScroll(reachHistory)) {
                            Box(Modifier.fillMaxSize().verticalScroll(wrapScroll)) {
                                TerminalGrid(snapshot, metrics, wrapColumns.takeIf { it < snapshot.columns })
                            }
                        }
                    }
                    // True geometry: nothing folded, the reader pans in both directions, and the
                    // vertical end of the canvas hands the drag over to tmux as well.
                    TerminalView.PAN -> {
                        val panScroll = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.fillMaxSize().then(pinch).nestedScroll(reachHistory)) {
                            Box(Modifier.fillMaxSize().horizontalScroll(rememberScrollState()).verticalScroll(panScroll)) {
                                TerminalGrid(snapshot, metrics)
                            }
                        }
                    }
                }
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
            draft = draft, onDraftChange = onDraftChange,
            dictation = dictation, dictationLanguage = settings.dictationLanguage, sendOnDictationEnd = settings.sendOnDictationEnd,
        )
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun MirrorTerminalScreen(
    snapshot: TerminalSnapshot?, loading: Boolean, error: Int?, errorDetail: String?, sending: Boolean, reconnecting: Boolean, connected: Boolean,
    onRefresh: () -> Unit, onReconnect: () -> Unit, onScroll: (Int) -> Unit, onSend: (String, Boolean, (Boolean) -> Unit) -> Unit,
    attachFallbackDetail: String?, onRequestReal: (Int, Int) -> Unit, draft: String, onDraftChange: (String) -> Unit,
    windowPinned: Boolean, onTogglePin: () -> Unit, activity: ActivityState,
    attachments: AttachViewModel?, attachTarget: AttachTarget?, dictation: DictationViewModel?, settings: AppSettings,
) {
    var viewMode by rememberSaveable { mutableStateOf(TerminalView.FIT) }
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
            ActivityMark(activity, Modifier.padding(start = 10.dp), size = 18.dp)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onTogglePin) {
                Icon(if (windowPinned) Icons.Rounded.Star else Icons.Rounded.StarBorder, stringResource(if (windowPinned) R.string.box_unpin else R.string.box_pin), tint = if (windowPinned) UniTheme.colors.warning else UniTheme.colors.muted)
            }
            // The clip: attach to this window, and paste the path or link into the composer.
            if (attachments != null && attachTarget != null) AttachButton(attachments, attachTarget, draft, onDraftChange)
            IconButton(onClick = onReconnect, enabled = (connected || error != null) && !reconnecting) {
                if (reconnecting) LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.accent)
                else Icon(Icons.Rounded.Sync, stringResource(R.string.terminal_reconnect), tint = UniTheme.colors.muted)
            }
            // Real terminal: a tmux client of the phone's size. The readable geometry is measured
            // here so the attach asks the host for exactly the size this screen can draw.
            var armReal by remember { mutableStateOf(false) }
            IconButton(onClick = { armReal = true }, enabled = connected) {
                Icon(Icons.Rounded.Link, stringResource(R.string.real_terminal_start), tint = UniTheme.colors.muted)
            }
            RealTerminalStarter(armReal) { columns, rows -> armReal = false; onRequestReal(columns, rows) }
            if (snapshot != null) IconButton(onClick = { viewMode = viewMode.next }) {
                // The icon announces the mode the tap switches to.
                Icon(
                    when (viewMode) { TerminalView.FIT -> Icons.Rounded.ZoomIn; TerminalView.WRAP -> Icons.Rounded.OpenInFull; TerminalView.PAN -> Icons.Rounded.ZoomOutMap },
                    stringResource(when (viewMode) { TerminalView.FIT -> R.string.screen_actual_size; TerminalView.WRAP -> R.string.screen_pan; TerminalView.PAN -> R.string.screen_fit_width }),
                    tint = UniTheme.colors.muted,
                )
            }
            IconButton(onClick = onRefresh, enabled = !loading) {
                if (loading) LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.accent)
                else Icon(Icons.Rounded.Refresh, stringResource(R.string.screen_refresh), tint = UniTheme.colors.muted)
            }
        }
        error?.let {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 6.dp)) {
                Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                errorDetail?.let { detail -> Text(stringResource(R.string.host_error_code, detail), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall) }
            }
        }
        // A refused attach must say so: silence here reads as "the real terminal is broken".
        if (error == null) attachFallbackDetail?.let { detail ->
            Text(
                stringResource(R.string.real_terminal_fell_back, detail),
                Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
                color = UniTheme.colors.warning, style = MaterialTheme.typography.labelSmall,
            )
        }
        val frameShape = UniTheme.shapes.card
        Box(
            Modifier.weight(1f).fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp)
                .clip(frameShape)
                .background(Color(parseColor(snapshot?.background, 0xFF070D20.toInt())))
                .border(1.dp, UniTheme.colors.outlineFade, frameShape),
        ) {
            if (snapshot == null) {
                Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    if (loading) LoadingIndicator(color = UniTheme.colors.accent)
                    Text(stringResource(if (loading) R.string.screen_loading else R.string.screen_unavailable), Modifier.padding(top = 16.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyMedium)
                }
            } else BoxWithConstraints(Modifier.fillMaxSize()) {
                val viewport = IntSize(constraints.maxWidth, constraints.maxHeight)
                // Captured here: the nested scroll boxes are outside BoxWithConstraints' scope.
                val viewportHeight = viewport.height
                val metrics = rememberTerminalMetrics(snapshot, if (viewMode == TerminalView.FIT) viewport else null)
                val scroll by rememberUpdatedState(onScroll)
                val history = snapshot.scrollbackRows > 0
                when {
                    // With exported history the whole canvas scrolls locally, newest lines at the bottom.
                    viewMode == TerminalView.FIT && history -> {
                        val scrollState = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.fillMaxSize().verticalScroll(scrollState), contentAlignment = Alignment.TopCenter) {
                            TerminalGrid(snapshot, metrics, scroll = scrollState, viewportHeightPx = viewportHeight)
                        }
                    }
                    viewMode == TerminalView.WRAP -> {
                        // Readable size; long desktop rows wrap at the inner width instead of scrolling sideways.
                        val wrapColumns = ((viewport.width - 16f) / metrics.cellWidth).toInt().coerceAtLeast(8)
                        val wrapScroll = rememberPinnedScrollState(snapshot, metrics.lineHeight)
                        Box(Modifier.verticalScroll(wrapScroll)) {
                            TerminalGrid(snapshot, metrics, wrapColumns.takeIf { it < snapshot.columns }, scroll = wrapScroll, viewportHeightPx = viewportHeight)
                        }
                    }
                    viewMode == TerminalView.PAN -> {
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
            draft = draft, onDraftChange = onDraftChange,
            dictation = dictation, dictationLanguage = settings.dictationLanguage, sendOnDictationEnd = settings.sendOnDictationEnd,
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
/** Reading geometry for this device. The desktop PTY keeps its own columns and rows. */
/** How much of a flick past the canvas edge reaches tmux: a fraction of a second of it, capped. */
private const val FLING_SECONDS = 0.12f
private const val FLING_MAX_LINES = 24

/** Reader-controlled zoom bounds: below 0.6 the text stops being legible, above 5 it is huge. */
private const val MIN_ZOOM = 0.6f
private const val MAX_ZOOM = 5f

private class TerminalMetrics(val fontSize: Float, val cellWidth: Float, val lineHeight: Float, val columns: Int, val rows: Int) {
    val widthPx: Float get() = columns * cellWidth + 16f
    val heightPx: Float get() = rows * lineHeight + 16f
}

@Composable
private fun rememberTerminalMetrics(snapshot: TerminalSnapshot, fit: IntSize?, zoom: Float = 1f): TerminalMetrics {
    val density = LocalDensity.current
    val normalFontSize = with(density) { 13.sp.toPx() }
    return remember(snapshot.columns, snapshot.rows, fit, normalFontSize, zoom) {
        val normalCell = Paint().apply { textSize = normalFontSize; typeface = Typeface.MONOSPACE }.measureText("M")
        val normalLine = normalFontSize * 1.35f
        val scale = if (fit == null) 1f else minOf(
            (fit.width - 16f).coerceAtLeast(1f) / (snapshot.columns * normalCell),
            (fit.height - 16f).coerceAtLeast(1f) / (snapshot.rows * normalLine),
            1f,
        )
        // The fitted scale never magnifies on its own; `zoom` is the reader's own decision and is
        // free to go past 1, which is what makes an 80x23 window usable on a tall phone screen.
        val fontSize = normalFontSize * scale * zoom
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
                    // Snapped outwards: at readable font sizes, cell edges that fall between
                    // pixels leave hairline gaps that turn a solid tmux selection into stripes.
                    canvas.drawRect(
                        kotlin.math.floor(x), kotlin.math.floor(y),
                        kotlin.math.ceil(x + cells * cellWidth), kotlin.math.ceil(y + lineHeight),
                        paint,
                    )
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
