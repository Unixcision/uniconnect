package com.unixcision.uniconnect.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.components.BoxMonogram
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.PillTone
import com.unixcision.uniconnect.android.ui.components.StatusPill
import com.unixcision.uniconnect.android.ui.components.themedTone

private enum class Level { LOADING, LIST, MACHINE, TERMINAL }

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MachinesScreen(model: MachinesViewModel, onEnableNotifications: (String) -> Unit) {
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { model.pauseLiveConnection() }
    LifecycleEventEffect(Lifecycle.Event.ON_START) { model.resumeLiveConnection() }
    val state by model.state.collectAsStateWithLifecycle()
    val machine = state.machines.firstOrNull { it.id == state.selectedMachine }
    val connection = machine?.let { state.connections[it.id] }
    val workspace = connection?.snapshot?.workspaces?.firstOrNull { it.id == state.selectedWorkspace }
    val window = workspace?.windows?.firstOrNull { it.id == state.selectedWindow }
    // Against a host that keeps favourites itself, the phone's own copy is not shown.
    val overrides = machine?.takeIf { connection?.snapshot?.keepsBoxes != true }?.let { state.overrides[it.id] } ?: BoxOverrides()
    var removing by remember { mutableStateOf<Machine?>(null) }
    var menuOpen by remember { mutableStateOf(false) }
    BackHandler(enabled = machine != null, onBack = model::back)
    val level = when {
        state.loading -> Level.LOADING
        window != null -> Level.TERMINAL
        machine != null -> Level.MACHINE
        else -> Level.LIST
    }

    // A flat ground in every theme: no gradient, no glow.
    Box(Modifier.fillMaxSize().background(UniTheme.colors.background)) {
        // System bars and cutout only: the IME is padded once, by the screen that hosts the composer.
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout)).widthIn(max = 840.dp).align(Alignment.TopCenter)) {
            AppHeader(
                compact = level == Level.TERMINAL,
                title = window?.name ?: machine?.name ?: stringResource(R.string.app_name),
                subtitle = when {
                    window != null -> "${machine?.name.orEmpty()} · ${workspace?.name.orEmpty()}"
                    machine != null -> machine.endpoint.displayAddress
                    else -> stringResource(R.string.home_eyebrow)
                },
                showBack = machine != null,
                onBack = model::back,
                monogramSeed = machine?.name,
                pill = when {
                    machine == null -> null
                    connection?.connected == true -> stringResource(R.string.connected_machine) to PillTone.Live
                    connection?.checking == true -> stringResource(R.string.checking_machine) to PillTone.Busy
                    else -> stringResource(R.string.saved_machine) to PillTone.Idle
                },
            ) {
                when (level) {
                    Level.LIST -> Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = model::showSettings) {
                            Icon(Icons.Rounded.Settings, stringResource(R.string.settings), tint = UniTheme.colors.muted)
                        }
                        IconButton(onClick = { model.refreshMachineStates(force = true) }, enabled = !state.refreshing) {
                            if (state.refreshing) LoadingIndicator(Modifier.size(22.dp), color = UniTheme.colors.accent)
                            else Icon(Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), tint = UniTheme.colors.muted)
                        }
                        FilledIconButton(onClick = model::showAdd, colors = IconButtonDefaults.filledIconButtonColors(containerColor = UniTheme.colors.accent, contentColor = UniTheme.colors.onAccent)) {
                            Icon(Icons.Rounded.Add, stringResource(R.string.add_machine))
                        }
                    }
                    Level.MACHINE -> Box {
                        IconButton(onClick = { menuOpen = true }) { Icon(Icons.Rounded.MoreVert, stringResource(R.string.machine_menu), tint = UniTheme.colors.muted) }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, containerColor = UniTheme.colors.surfaceRaised) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.edit_machine)) },
                                leadingIcon = { Icon(Icons.Rounded.Edit, null, tint = UniTheme.colors.accent) },
                                onClick = { menuOpen = false; machine?.let(model::showEdit) },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.remove), color = UniTheme.colors.danger) },
                                leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null, tint = UniTheme.colors.danger) },
                                onClick = { menuOpen = false; removing = machine },
                            )
                        }
                    }
                    else -> {}
                }
            }
            state.error?.let { ErrorNotice(it, model::dismissError) }
            AnimatedContent(
                targetState = level,
                transitionSpec = {
                    val forward = targetState.ordinal >= initialState.ordinal
                    (fadeIn() + slideInHorizontally { if (forward) it / 8 else -it / 8 }) togetherWith
                        (fadeOut() + slideOutHorizontally { if (forward) -it / 8 else it / 8 })
                },
                label = "level",
            ) { target ->
                when (target) {
                    Level.LOADING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingIndicator(color = UniTheme.colors.accent) }
                    Level.TERMINAL -> key(machine?.id, workspace?.id, window?.id) {
                        TerminalScreen(
                            snapshot = state.terminal, loading = state.terminalLoading, error = state.terminalError, errorDetail = state.terminalErrorDetail,
                            sending = state.inputSending, reconnecting = state.reconnecting, connected = connection?.connected == true,
                            onRefresh = model::refreshTerminal, onReconnect = model::reconnectWindow,
                            onScroll = model::scrollTerminal, onSend = model::sendInput,
                            real = state.realTerminal, attachUnsupported = machine?.id in state.attachUnsupported,
                            attachFallbackDetail = state.attachFallbackDetail,
                            onStartReal = model::startRealTerminal, onStopReal = model::stopRealTerminal,
                            onPty = model::sendPty, onPtyWheel = model::wheelPty, onPtyResize = model::resizePty,
                            onLeaveCopyMode = model::leaveCopyMode, settings = state.settings,
                            resumeReal = state.resumeRealTerminal, view = state.terminalView, zoom = state.terminalZoom,
                            onView = model::setTerminalView, onZoom = model::setTerminalZoom, onReconnectReal = model::reconnectRealTerminal,
                            draft = state.draft, onDraftChange = model::updateDraft,
                            windowPinned = window?.isPinned == true || window?.id in overrides.pinnedWindows,
                            onTogglePin = { window?.let { model.toggleWindowPinned(it.id) } },
                            activity = window?.activity?.state ?: ActivityState.UNKNOWN,
                        )
                    }
                    Level.MACHINE -> if (machine != null) MachineBoxesScreen(
                        machine = machine, connection = connection ?: MachinesViewModel.Connection(),
                        selectedWorkspaceID = state.selectedWorkspace, noticeLink = state.notificationLinks[machine.id],
                        onEnableNotices = { onEnableNotifications(machine.id) }, onDisableNotices = { model.disableNotifications(machine.id) },
                        onConnect = { model.connect(machine) }, onCreateWorkspace = { model.showCreate(false) },
                        onCreateWindow = { model.showCreate(true) }, onSelectWorkspace = model::selectWorkspace, onSelectWindow = model::selectWindow,
                        overrides = overrides, hostKeepsOrder = state.hostKeepsOrder[machine.id],
                        onToggleWorkspacePin = model::toggleWorkspacePinned, onToggleWindowPin = model::toggleWindowPinned,
                        onMoveWorkspace = model::moveWorkspace, onMoveWindow = model::moveWindow,
                    )
                    Level.LIST -> PullToRefreshBox(
                        isRefreshing = state.refreshing,
                        onRefresh = { model.refreshMachineStates(force = true) },
                    ) { MachineList(state.machines, state.connections, model::showAdd, model::selectMachine) }
                }
            }
        }
    }
    if (state.showingSettings) SettingsSheet(state.settings, model::updateSettings, model::dismissSettings)
    if (state.adding) MachineSheet(state.saving, state.formError, onDismiss = model::dismissAdd, onSave = model::saveMachine)
    state.editing?.let { target ->
        MachineSheet(state.saving, state.formError, machine = target, onDismiss = model::dismissEdit, onSave = model::saveMachine)
    }
    state.creation?.let { CreateResourceSheet(it, state.creating, state.creationError, model::dismissCreate, model::create) }
    removing?.let { target ->
        AlertDialog(
            onDismissRequest = { removing = null },
            containerColor = UniTheme.colors.surfaceRaised,
            icon = { Icon(Icons.Rounded.DeleteOutline, null, tint = UniTheme.colors.danger) },
            title = { Text(stringResource(R.string.remove_title)) },
            text = { Text(stringResource(R.string.remove_note), color = UniTheme.colors.muted) },
            confirmButton = { TextButton(onClick = { model.removeMachine(target); removing = null }) { Text(stringResource(R.string.remove), color = UniTheme.colors.danger) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun AppHeader(
    compact: Boolean, title: String, subtitle: String, showBack: Boolean, onBack: () -> Unit,
    monogramSeed: String?, pill: Pair<String, PillTone>?, actions: @Composable () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = if (compact) 2.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showBack) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
        else Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.padding(start = 8.dp).size(44.dp))
        if (monogramSeed != null && !compact) BoxMonogram(monogramSeed, Modifier.padding(start = 4.dp), size = 40.dp, selected = true)
        // Inside a machine the title and subtitle are names and addresses: identifier type.
        val identifier = if (showBack) UniTheme.type.identifierFamily else null
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(title, style = if (compact) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleLarge, fontFamily = identifier, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(subtitle, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelSmall, fontFamily = identifier, color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                // The state pill shares the subtitle line so the machine name keeps its full width.
                if (pill != null && !compact) StatusPill(pill.first, pill.second)
            }
        }
        actions()
    }
}

@Composable
private fun MachineList(machines: List<Machine>, connections: Map<String, MachinesViewModel.Connection>, onAdd: () -> Unit, onSelect: (String) -> Unit) {
    val spacing = UniTheme.spacing
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = spacing.page, end = spacing.page, top = 12.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(spacing.gap)) {
        item {
            Text(stringResource(R.string.home_title), style = MaterialTheme.typography.displaySmall)
            Text(stringResource(R.string.home_subtitle), Modifier.padding(top = 6.dp, bottom = 8.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyLarge)
        }
        if (machines.isEmpty()) item {
            GlassCard(Modifier.fillMaxWidth().padding(top = 12.dp), accent = UniTheme.colors.accent) {
                Column(Modifier.padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(120.dp))
                    Text(stringResource(R.string.empty_title), Modifier.padding(top = 18.dp), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.empty_detail), Modifier.padding(top = 10.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = onAdd, modifier = Modifier.fillMaxWidth().padding(top = 26.dp), shape = UniTheme.shapes.button, contentPadding = PaddingValues(18.dp)) {
                        Icon(Icons.Rounded.Add, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        if (machines.isNotEmpty()) item {
            Column(verticalArrangement = Arrangement.spacedBy(UniTheme.layout.rowGap(spacing))) { machines.forEach { machine -> key(machine.id) { MachineRow(machine, connections[machine.id]) { onSelect(machine.id) } } } }
        }
        item {
            Row(Modifier.padding(top = 12.dp, start = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(28.dp).background(UniTheme.colors.success.copy(alpha = .12f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Shield, null, Modifier.size(15.dp), tint = UniTheme.colors.success)
                }
                Column {
                    Text(stringResource(R.string.security_note), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
                    Text(stringResource(R.string.hierarchy_hint), style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.accent)
                }
            }
        }
    }
}

/** One saved machine: a card or a row between rules, as the theme draws its lists. */
@Composable
private fun MachineRow(machine: Machine, connection: MachinesViewModel.Connection?, onSelect: () -> Unit) {
    val identifier = UniTheme.type.identifierFamily
    val tone = themedTone(machine.name)
    GlassCard(Modifier.fillMaxWidth(), accent = if (connection?.connected == true) UniTheme.colors.success else tone, onClick = onSelect, style = UniTheme.layout.rowsAs) {
        Row(Modifier.fillMaxWidth().padding(UniTheme.layout.cardPadding), verticalAlignment = Alignment.CenterVertically) {
            BoxMonogram(machine.name, size = 54.dp, selected = connection?.connected == true, tone = tone)
            Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                Text(machine.name, style = MaterialTheme.typography.titleMedium, fontFamily = identifier, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(machine.endpoint.displayAddress, color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall, fontFamily = identifier, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    when {
                        connection?.connected == true -> StatusPill(stringResource(R.string.connected_machine), PillTone.Live)
                        connection?.checking == true -> StatusPill(stringResource(R.string.checking_machine), PillTone.Busy)
                        else -> StatusPill(stringResource(R.string.saved_machine), PillTone.Idle)
                    }
                    connection?.snapshot?.let { snapshot ->
                        Text(pluralStringResource(R.plurals.window_count, snapshot.workspaces.sumOf { it.windows.size }, snapshot.workspaces.sumOf { it.windows.size }),
                            style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted)
                    }
                }
            }
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = UniTheme.colors.muted)
        }
    }
}

@Composable
fun ErrorNotice(message: Int, onDismiss: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = UniTheme.spacing.page, vertical = 4.dp), color = MaterialTheme.colorScheme.errorContainer, shape = UniTheme.shapes.card) {
        Row(Modifier.padding(start = 16.dp, top = 6.dp, bottom = 6.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(message), Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall)
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.dismiss), tint = MaterialTheme.colorScheme.onErrorContainer) }
        }
    }
}
