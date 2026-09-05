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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.components.BoxMonogram
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.PillTone
import com.unixcision.uniconnect.android.ui.components.StatusPill
import com.unixcision.uniconnect.android.ui.components.boxTone

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
    var removing by remember { mutableStateOf<Machine?>(null) }
    var menuOpen by remember { mutableStateOf(false) }
    BackHandler(enabled = machine != null, onBack = model::back)
    val level = when {
        state.loading -> Level.LOADING
        window != null -> Level.TERMINAL
        machine != null -> Level.MACHINE
        else -> Level.LIST
    }

    Box(Modifier.fillMaxSize().background(Brand.Night).drawBehind {
        drawRect(Brush.verticalGradient(listOf(Brand.DeepBlue, Brand.Night, Brand.Night)))
        drawCircle(Brush.radialGradient(listOf(Brand.Violet.copy(alpha = .22f), Color.Transparent), center = Offset(size.width * .95f, -size.height * .05f), radius = size.width * .7f),
            radius = size.width * .7f, center = Offset(size.width * .95f, -size.height * .05f))
        drawCircle(Brush.radialGradient(listOf(Brand.Cyan.copy(alpha = .12f), Color.Transparent), center = Offset(0f, size.height * .35f), radius = size.width * .6f),
            radius = size.width * .6f, center = Offset(0f, size.height * .35f))
    }) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().widthIn(max = 840.dp).align(Alignment.TopCenter)) {
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
                    Level.LIST -> FilledIconButton(onClick = model::showAdd, colors = IconButtonDefaults.filledIconButtonColors(containerColor = Brand.Cyan, contentColor = Brand.Night)) {
                        Icon(Icons.Rounded.Add, stringResource(R.string.add_machine))
                    }
                    Level.MACHINE -> Box {
                        IconButton(onClick = { menuOpen = true }) { Icon(Icons.Rounded.MoreVert, stringResource(R.string.machine_menu), tint = Brand.Muted) }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }, containerColor = Brand.SurfaceHigh) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.remove), color = Brand.Coral) },
                                leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null, tint = Brand.Coral) },
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
                    Level.LOADING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingIndicator(color = Brand.Cyan) }
                    Level.TERMINAL -> key(machine?.id, workspace?.id, window?.id) {
                        TerminalScreen(
                            snapshot = state.terminal, loading = state.terminalLoading, error = state.terminalError, errorDetail = state.terminalErrorDetail,
                            sending = state.inputSending, reconnecting = state.reconnecting, connected = connection?.connected == true,
                            onRefresh = model::refreshTerminal, onReconnect = model::reconnectWindow,
                            onScroll = model::scrollTerminal, onSend = model::sendInput,
                        )
                    }
                    Level.MACHINE -> if (machine != null) MachineBoxesScreen(
                        machine = machine, connection = connection ?: MachinesViewModel.Connection(),
                        selectedWorkspaceID = state.selectedWorkspace, noticeLink = state.notificationLinks[machine.id],
                        onEnableNotices = { onEnableNotifications(machine.id) }, onDisableNotices = { model.disableNotifications(machine.id) },
                        onConnect = { model.connect(machine) }, onCreateWorkspace = { model.showCreate(false) },
                        onCreateWindow = { model.showCreate(true) }, onSelectWorkspace = model::selectWorkspace, onSelectWindow = model::selectWindow,
                    )
                    Level.LIST -> MachineList(state.machines, state.connections, model::showAdd, model::selectMachine)
                }
            }
        }
    }
    if (state.adding) AddMachineSheet(state.saving, state.formError, model::dismissAdd, model::saveMachine)
    state.creation?.let { CreateResourceSheet(it, state.creating, state.creationError, model::dismissCreate, model::create) }
    removing?.let { target ->
        AlertDialog(
            onDismissRequest = { removing = null },
            containerColor = Brand.SurfaceHigh,
            icon = { Icon(Icons.Rounded.DeleteOutline, null, tint = Brand.Coral) },
            title = { Text(stringResource(R.string.remove_title)) },
            text = { Text(stringResource(R.string.remove_note), color = Brand.Muted) },
            confirmButton = { TextButton(onClick = { model.removeMachine(target); removing = null }) { Text(stringResource(R.string.remove), color = Brand.Coral) } },
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
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(title, style = if (compact) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(subtitle, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelSmall, color = Brand.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                // The state pill shares the subtitle line so the machine name keeps its full width.
                if (pill != null && !compact) StatusPill(pill.first, pill.second)
            }
        }
        actions()
    }
}

@Composable
private fun MachineList(machines: List<Machine>, connections: Map<String, MachinesViewModel.Connection>, onAdd: () -> Unit, onSelect: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Text(stringResource(R.string.home_title), style = MaterialTheme.typography.displaySmall)
            Text(stringResource(R.string.home_subtitle), Modifier.padding(top = 6.dp, bottom = 8.dp), color = Brand.Muted, style = MaterialTheme.typography.bodyLarge)
        }
        if (machines.isEmpty()) item {
            GlassCard(Modifier.fillMaxWidth().padding(top = 12.dp), shape = RoundedCornerShape(30.dp), accent = Brand.Violet) {
                Column(Modifier.padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(120.dp))
                    Text(stringResource(R.string.empty_title), Modifier.padding(top = 18.dp), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.empty_detail), Modifier.padding(top = 10.dp), color = Brand.Muted, style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = onAdd, modifier = Modifier.fillMaxWidth().padding(top = 26.dp), shape = RoundedCornerShape(18.dp), contentPadding = PaddingValues(18.dp)) {
                        Icon(Icons.Rounded.Add, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        items(machines, key = { it.id }) { machine ->
            val connection = connections[machine.id]
            val tone = boxTone(machine.name)
            GlassCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(24.dp), accent = if (connection?.connected == true) Brand.Mint else tone, onClick = { onSelect(machine.id) }) {
                Row(Modifier.fillMaxWidth().padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                    BoxMonogram(machine.name, size = 54.dp, selected = connection?.connected == true, tone = tone)
                    Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                        Text(machine.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(machine.endpoint.displayAddress, color = Brand.Muted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            when {
                                connection?.connected == true -> StatusPill(stringResource(R.string.connected_machine), PillTone.Live)
                                connection?.checking == true -> StatusPill(stringResource(R.string.checking_machine), PillTone.Busy)
                                else -> StatusPill(stringResource(R.string.saved_machine), PillTone.Idle)
                            }
                            connection?.snapshot?.let { snapshot ->
                                Text(pluralStringResource(R.plurals.window_count, snapshot.workspaces.sumOf { it.windows.size }, snapshot.workspaces.sumOf { it.windows.size }),
                                    style = MaterialTheme.typography.labelSmall, color = Brand.Muted)
                            }
                        }
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Brand.Muted)
                }
            }
        }
        item {
            Row(Modifier.padding(top = 12.dp, start = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(28.dp).background(Brand.Mint.copy(alpha = .12f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Shield, null, Modifier.size(15.dp), tint = Brand.Mint)
                }
                Column {
                    Text(stringResource(R.string.security_note), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
                    Text(stringResource(R.string.hierarchy_hint), style = MaterialTheme.typography.labelSmall, color = Brand.Violet)
                }
            }
        }
    }
}

@Composable
fun ErrorNotice(message: Int, onDismiss: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp), color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(18.dp)) {
        Row(Modifier.padding(start = 16.dp, top = 6.dp, bottom = 6.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(message), Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall)
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.dismiss), tint = MaterialTheme.colorScheme.onErrorContainer) }
        }
    }
}
