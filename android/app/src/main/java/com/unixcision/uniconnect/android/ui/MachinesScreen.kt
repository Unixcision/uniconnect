package com.unixcision.uniconnect.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.compose.ui.res.pluralStringResource
import com.unixcision.uniconnect.android.domain.NotificationLinkState

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
    BackHandler(enabled = machine != null, onBack = model::back)

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Brand.DeepBlue, Brand.Night, Brand.Night)))) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().widthIn(max = 840.dp).align(Alignment.TopCenter)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                if (machine != null) IconButton(onClick = model::back) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back))
                } else Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(46.dp))
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text(window?.name ?: workspace?.name ?: machine?.name ?: stringResource(R.string.app_name),
                        style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(when {
                        window != null -> stringResource(R.string.windows)
                        workspace != null -> stringResource(R.string.workspaces)
                        machine != null -> machine.endpoint.displayAddress
                        else -> stringResource(R.string.private_network)
                    }, style = MaterialTheme.typography.labelSmall, color = Brand.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (machine == null) IconButton(onClick = model::showAdd) {
                    Icon(Icons.Rounded.Add, stringResource(R.string.add_machine), tint = Brand.Cyan)
                } else IconButton(onClick = { removing = machine }) {
                    Icon(Icons.Rounded.DeleteOutline, stringResource(R.string.remove), tint = Brand.Muted)
                }
            }
            state.error?.let { ErrorNotice(it, model::dismissError) }
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                window != null -> TerminalScreen(state.terminal, state.terminalLoading, state.terminalError, state.inputSending, connection?.connected == true, model::refreshTerminal, model::sendInput)
                workspace != null -> WorkspaceWindows(workspace, connection?.connected == true, { model.showCreate(true) }, model::selectWindow)
                machine != null -> MachineWorkspaces(machine, connection ?: MachinesViewModel.Connection(), state.notificationLinks[machine.id], { onEnableNotifications(machine.id) }, { model.disableNotifications(machine.id) }, { model.connect(machine) }, { model.showCreate(false) }, model::selectWorkspace)
                else -> MachineList(state.machines, state.connections, model::showAdd, model::selectMachine)
            }
        }
    }
    if (state.adding) AddMachineDialog(state.saving, state.formError, model::dismissAdd, model::saveMachine)
    state.creation?.let { CreateResourceDialog(it, state.creating, state.creationError, model::dismissCreate, model::create) }
    removing?.let { target ->
        AlertDialog(onDismissRequest = { removing = null }, title = { Text(stringResource(R.string.remove_title)) },
            text = { Text(stringResource(R.string.remove_note)) },
            confirmButton = { TextButton(onClick = { model.removeMachine(target); removing = null }) { Text(stringResource(R.string.remove)) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
private fun MachineList(machines: List<Machine>, connections: Map<String, MachinesViewModel.Connection>, onAdd: () -> Unit, onSelect: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 24.dp, end = 24.dp, top = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Text(stringResource(R.string.home_title), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text(stringResource(R.string.home_subtitle), Modifier.padding(top = 8.dp), color = Brand.Muted)
        }
        if (machines.isEmpty()) item {
            Surface(Modifier.fillMaxWidth().padding(top = 24.dp), shape = RoundedCornerShape(28.dp), color = Brand.Surface.copy(alpha = .85f), border = BorderStroke(1.dp, Brand.Outline)) {
                Column(Modifier.padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(132.dp))
                    Text(stringResource(R.string.empty_title), Modifier.padding(top = 20.dp), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(R.string.empty_detail), Modifier.padding(top = 12.dp), color = Brand.Muted)
                    Button(onClick = onAdd, modifier = Modifier.fillMaxWidth().padding(top = 28.dp), shape = RoundedCornerShape(16.dp), contentPadding = PaddingValues(16.dp)) {
                        Icon(Icons.Rounded.Add, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.add_machine))
                    }
                }
            }
        }
        items(machines, key = { it.id }) { machine ->
            val connected = connections[machine.id]?.connected == true
            Card(onClick = { onSelect(machine.id) }, shape = RoundedCornerShape(22.dp), border = BorderStroke(1.dp, Brand.Outline), colors = CardDefaults.cardColors(containerColor = Brand.Surface)) {
                Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = RoundedCornerShape(14.dp), color = Brand.Violet.copy(alpha = .12f)) {
                        Icon(Icons.Rounded.Computer, null, Modifier.padding(14.dp).size(26.dp), tint = Brand.Violet)
                    }
                    Column(Modifier.weight(1f).padding(horizontal = 16.dp)) {
                        Text(machine.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(machine.endpoint.host, color = Brand.Muted, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(stringResource(if (connected) R.string.connected_machine else R.string.saved_machine), Modifier.padding(top = 8.dp), color = if (connected) Brand.Cyan else Brand.Muted, style = MaterialTheme.typography.labelSmall)
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Brand.Muted)
                }
            }
        }
        item {
            Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.hierarchy_hint), style = MaterialTheme.typography.labelMedium, color = Brand.Violet)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.Shield, null, Modifier.size(16.dp), tint = Brand.Muted)
                    Text(stringResource(R.string.security_note), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
                }
            }
        }
    }
}

@Composable
private fun MachineWorkspaces(machine: Machine, connection: MachinesViewModel.Connection, noticeLink: NotificationLinkState?, onEnableNotices: () -> Unit, onDisableNotices: () -> Unit, onConnect: () -> Unit, onCreate: () -> Unit, onSelect: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { Text(stringResource(R.string.workspaces), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold) }
        if (connection.connected || noticeLink != null) item { NotificationConnectionCard(noticeLink, connection.connected, onEnableNotices, onDisableNotices) }
        if (connection.connected) item {
            OutlinedButton(onClick = onCreate) { Icon(Icons.Rounded.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.new_workspace)) }
        }
        if (connection.snapshot != null && !connection.connected) item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(connection.error ?: R.string.checking_machine), color = Brand.Muted)
                if (!connection.checking) TextButton(onClick = onConnect) { Text(stringResource(R.string.check_connection)) }
            }
        }
        if (connection.snapshot == null) item {
            Surface(shape = RoundedCornerShape(24.dp), color = Brand.Surface) {
                Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Icon(Icons.Rounded.Lock, null, tint = Brand.Violet)
                    Text(stringResource(if (connection.error == R.string.approval_required) R.string.approval_pending_title else R.string.not_connected_title), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(connection.error ?: R.string.not_connected_detail), color = Brand.Muted)
                    Button(onClick = onConnect, enabled = !connection.checking, modifier = Modifier.fillMaxWidth()) {
                        if (connection.checking) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        else Icon(Icons.Rounded.Sync, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(if (connection.checking) R.string.checking_machine else if (connection.error != null) R.string.retry else R.string.check_connection))
                    }
                }
            }
        }
        connection.snapshot?.let { snapshot ->
            if (snapshot.workspaces.isEmpty()) item { Text(stringResource(R.string.no_workspaces), color = Brand.Muted) }
            items(snapshot.workspaces, key = { it.id }) { workspace ->
                ListItem(headlineContent = { Text(workspace.name) },
                    supportingContent = { Text(pluralStringResource(R.plurals.window_count, workspace.windows.size, workspace.windows.size)) },
                    leadingContent = { Icon(Icons.Rounded.Folder, null, tint = Brand.Violet) },
                    trailingContent = { TextButton(onClick = { onSelect(workspace.id) }) { Text(stringResource(when (workspace.isSSH) { true -> R.string.ssh_workspace; false -> R.string.local_workspace; null -> R.string.open_workspace })) } },
                    colors = ListItemDefaults.colors(containerColor = Brand.Surface))
            }
        }
    }
}

@Composable
private fun WorkspaceWindows(workspace: RemoteWorkspace, connected: Boolean, onCreate: () -> Unit, onSelect: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (workspace.isSSH != null) item {
            OutlinedButton(onClick = onCreate, enabled = connected) { Icon(Icons.Rounded.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.new_window)) }
        }
        item { Text(stringResource(R.string.windows), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold) }
        if (workspace.windows.isEmpty()) item { Text(stringResource(R.string.no_windows), color = Brand.Muted) }
        items(workspace.windows, key = { it.id }) { window ->
            Card(onClick = { onSelect(window.id) }, colors = CardDefaults.cardColors(containerColor = Brand.Surface)) {
                Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Terminal, null, tint = Brand.Cyan)
                    Text(window.name, Modifier.weight(1f).padding(horizontal = 16.dp))
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Brand.Muted)
                }
            }
        }
    }
}

@Composable
private fun EmptyNotice(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, detail: String) {
    Column(Modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center) {
        Icon(icon, null, Modifier.size(40.dp), tint = Brand.Violet)
        Text(title, Modifier.padding(top = 24.dp), style = MaterialTheme.typography.headlineSmall)
        Text(detail, Modifier.padding(top = 12.dp), color = Brand.Muted)
    }
}

@Composable
private fun ErrorNotice(message: Int, onDismiss: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = 24.dp), color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(16.dp)) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(message), Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer)
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.dismiss)) }
        }
    }
}

@Composable
private fun AddMachineDialog(saving: Boolean, error: Int?, onDismiss: () -> Unit, onSave: (String, String, String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var address by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf(MachineEndpoint.DEFAULT_PORT.toString()) }
    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(28.dp), color = Brand.Surface) {
            Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()).imePadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(stringResource(R.string.add_machine), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Text(stringResource(R.string.machine_form_note), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.machine_name)) }, singleLine = true, enabled = !saving)
                OutlinedTextField(address, { address = it }, label = { Text(stringResource(R.string.machine_address)) }, supportingText = { Text(stringResource(R.string.machine_address_hint)) }, singleLine = true, enabled = !saving, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                OutlinedTextField(port, { port = it }, label = { Text(stringResource(R.string.machine_port)) }, singleLine = true, enabled = !saving, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                Button(onClick = { onSave(name, address, port) }, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                    if (saving) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text(stringResource(R.string.save_machine))
                }
                TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
            }
        }
    }
}
