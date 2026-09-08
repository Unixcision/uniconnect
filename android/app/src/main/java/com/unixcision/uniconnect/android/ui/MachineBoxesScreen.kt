package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.BoxArrangement
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.RemoteWindow
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import com.unixcision.uniconnect.android.ui.components.BoxMonogram
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.components.boxTone

/**
 * One screen for a machine: a rail of workspace monograms (like the desktop's compact sidebar)
 * and, below it, the windows of the selected workspace. Selection is host-owned state only.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalFoundationApi::class)
@Composable
fun MachineBoxesScreen(
    machine: Machine,
    connection: MachinesViewModel.Connection,
    selectedWorkspaceID: String?,
    noticeLink: NotificationLinkState?,
    onEnableNotices: () -> Unit,
    onDisableNotices: () -> Unit,
    onConnect: () -> Unit,
    onCreateWorkspace: () -> Unit,
    onCreateWindow: () -> Unit,
    onSelectWorkspace: (String) -> Unit,
    onSelectWindow: (String) -> Unit,
    overrides: BoxOverrides = BoxOverrides(),
    hostKeepsOrder: Boolean? = null,
    onToggleWorkspacePin: (String) -> Unit = {},
    onToggleWindowPin: (String) -> Unit = {},
    onMoveWorkspace: (String, Int) -> Unit = { _, _ -> },
    onMoveWindow: (String, Int) -> Unit = { _, _ -> },
) {
    val snapshot = connection.snapshot
    val selected = snapshot?.workspaces?.firstOrNull { it.id == selectedWorkspaceID }
    val workspaces = snapshot?.let { BoxArrangement.workspaces(it, overrides) } ?: emptyList()
    val windows = selected?.let { BoxArrangement.windows(it, overrides) } ?: emptyList()
    val selectedPinned = selected != null && (selected.isPinned || selected.id in overrides.pinnedWorkspaces)
    // A long press opens the same sheet for either kind; which one is held here.
    var heldWorkspace by remember { mutableStateOf<RemoteWorkspace?>(null) }
    var heldWindow by remember { mutableStateOf<RemoteWindow?>(null) }
    // A lazy row keeps its scroll anchored to the first visible key, so a tile that jumps to the
    // front would slide out of view: after a change, the row scrolls to where the tile went.
    val workspaceRow = rememberLazyListState()
    var reveal by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(reveal, workspaces) {
        val id = reveal ?: return@LaunchedEffect
        val index = workspaces.indexOfFirst { it.id == id }
        // Near the start the whole head of the row fits, so show it from the first tile.
        if (index >= 0) { workspaceRow.animateScrollToItem(if (index < 3) 0 else index - 1); reveal = null }
    }
    heldWorkspace?.let { held ->
        BoxActionsSheet(held.name, R.string.box_actions_workspace, held.isPinned || held.id in overrides.pinnedWorkspaces,
            onTogglePin = { reveal = held.id; onToggleWorkspacePin(held.id) }, onMoveTop = { reveal = held.id; onMoveWorkspace(held.id, Int.MIN_VALUE) },
            onMoveUp = { reveal = held.id; onMoveWorkspace(held.id, -1) }, onMoveDown = { reveal = held.id; onMoveWorkspace(held.id, 1) }, onDismiss = { heldWorkspace = null })
    }
    heldWindow?.let { held ->
        BoxActionsSheet(held.name, R.string.box_actions_window, held.isPinned || held.id in overrides.pinnedWindows,
            onTogglePin = { onToggleWindowPin(held.id) }, onMoveTop = { onMoveWindow(held.id, Int.MIN_VALUE) },
            onMoveUp = { onMoveWindow(held.id, -1) }, onMoveDown = { onMoveWindow(held.id, 1) }, onDismiss = { heldWindow = null })
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (snapshot == null) item { NotConnectedCard(connection, onConnect) }
        if (snapshot != null && !connection.connected) item {
            GlassCard(Modifier.fillMaxWidth(), accent = Brand.Amber) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (connection.checking) LoadingIndicator(Modifier.size(28.dp), color = Brand.Amber) else Icon(Icons.Rounded.Sync, null, tint = Brand.Amber)
                    Text(stringResource(connection.error ?: R.string.checking_machine), Modifier.weight(1f), color = Brand.Muted, style = MaterialTheme.typography.bodySmall)
                    if (!connection.checking) TextButton(onClick = onConnect) { Text(stringResource(R.string.check_connection)) }
                }
            }
        }
        if (connection.connected || noticeLink != null) item { NotificationConnectionCard(noticeLink, connection.connected, onEnableNotices, onDisableNotices) }
        if (snapshot != null) {
            item {
                SectionLabel(stringResource(R.string.workspaces)) {
                    Text("${snapshot.workspaces.size}", style = MaterialTheme.typography.labelSmall, color = Brand.Muted)
                }
            }
            item {
                LazyRow(state = workspaceRow, horizontalArrangement = Arrangement.spacedBy(14.dp), contentPadding = PaddingValues(vertical = 4.dp)) {
                    items(workspaces, key = { it.id }) { workspace ->
                        WorkspaceTile(workspace, selected = workspace.id == selectedWorkspaceID, dimmed = !connection.connected,
                            pinned = workspace.isPinned || workspace.id in overrides.pinnedWorkspaces,
                            onClick = { onSelectWorkspace(workspace.id) }, onLongClick = { heldWorkspace = workspace })
                    }
                    if (connection.connected) item { NewWorkspaceTile(onCreateWorkspace) }
                }
            }
            if (snapshot.workspaces.isEmpty()) item {
                GlassCard(Modifier.fillMaxWidth(), accent = Brand.Violet) {
                    Column(Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(stringResource(R.string.no_workspaces), color = Brand.Muted)
                        if (connection.connected) Button(onClick = onCreateWorkspace, shape = RoundedCornerShape(16.dp)) {
                            Icon(Icons.Rounded.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.new_workspace))
                        }
                    }
                }
            }
            if (hostKeepsOrder == false) item {
                Text(stringResource(R.string.box_local_only), color = Brand.Amber, style = MaterialTheme.typography.labelSmall)
            }
            if (selected == null && snapshot.workspaces.isNotEmpty()) item {
                Text(stringResource(R.string.boxes_hint), Modifier.padding(top = 8.dp), color = Brand.Muted, style = MaterialTheme.typography.bodySmall)
            }
            if (selected != null) {
                item {
                    Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(selected.name, Modifier.weight(1f), style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            KindBadge(selected)
                            IconButton(onClick = { reveal = selected.id; onToggleWorkspacePin(selected.id) }, Modifier.size(36.dp)) {
                                Icon(if (selectedPinned) Icons.Rounded.Star else Icons.Rounded.StarBorder, stringResource(if (selectedPinned) R.string.box_unpin else R.string.box_pin),
                                    tint = if (selectedPinned) Brand.Amber else Brand.Muted)
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(pluralStringResource(R.plurals.window_count, selected.windows.size, selected.windows.size), Modifier.weight(1f), color = Brand.Muted, style = MaterialTheme.typography.bodySmall)
                            if (selected.isSSH != null) FilledTonalButton(onClick = onCreateWindow, enabled = connection.connected, shape = RoundedCornerShape(14.dp)) {
                                Icon(Icons.Rounded.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.new_window))
                            }
                        }
                    }
                }
                if (selected.windows.isEmpty()) item { Text(stringResource(R.string.no_windows), color = Brand.Muted, style = MaterialTheme.typography.bodySmall) }
                items(windows, key = { it.id }) { window ->
                    WindowRow(window, boxTone(selected.name), pinned = window.isPinned || window.id in overrides.pinnedWindows,
                        onClick = { onSelectWindow(window.id) }, onLongClick = { heldWindow = window })
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceTile(workspace: RemoteWorkspace, selected: Boolean, dimmed: Boolean, pinned: Boolean, onClick: () -> Unit, onLongClick: () -> Unit) {
    Column(Modifier.width(76.dp).combinedClickable(onClick = onClick, onLongClick = onLongClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            BoxMonogram(workspace.name, size = 64.dp, selected = selected, dimmed = dimmed)
            if (pinned) Box(
                Modifier.align(Alignment.TopStart).offset(x = (-4).dp, y = (-4).dp).size(20.dp)
                    .background(Brand.Night, CircleShape).border(1.dp, Brand.Outline, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(12.dp), tint = Brand.Amber) }
            if (workspace.windows.isNotEmpty()) Box(
                Modifier.align(Alignment.BottomEnd).offset(x = 4.dp, y = 4.dp).size(22.dp)
                    .background(Brand.Night, CircleShape).border(1.dp, Brand.Outline, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Text("${workspace.windows.size}", style = MaterialTheme.typography.labelSmall, color = Brand.Text) }
        }
        Text(workspace.name, style = MaterialTheme.typography.labelSmall, color = if (selected) Brand.Text else Brand.Muted,
            maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
    }
}

@Composable
private fun NewWorkspaceTile(onClick: () -> Unit) {
    Column(Modifier.width(76.dp).clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(64.dp).border(1.5.dp, Brand.Cyan.copy(alpha = .5f), RoundedCornerShape(23.dp)), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Add, stringResource(R.string.new_workspace), tint = Brand.Cyan)
        }
        Text(stringResource(R.string.new_workspace_tile), style = MaterialTheme.typography.labelSmall, color = Brand.Cyan)
    }
}

@Composable
fun KindBadge(workspace: RemoteWorkspace) {
    val (label, color) = when (workspace.isSSH) {
        true -> R.string.box_ssh_badge to Brand.Violet
        false -> R.string.box_local_badge to Brand.Cyan
        null -> R.string.box_unknown_badge to Brand.Muted
    }
    Text(stringResource(label), Modifier.background(color.copy(alpha = .14f), RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 3.dp),
        style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.Bold)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(window: RemoteWindow, tone: Color, pinned: Boolean, onClick: () -> Unit, onLongClick: () -> Unit) {
    GlassCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp)) {
        Row(Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(38.dp).background(tone.copy(alpha = .14f), RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Terminal, null, Modifier.size(20.dp), tint = tone)
            }
            Text(window.name, Modifier.weight(1f).padding(horizontal = 14.dp), style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(16.dp).padding(end = 2.dp), tint = Brand.Amber)
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = Brand.Muted)
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun NotConnectedCard(connection: MachinesViewModel.Connection, onConnect: () -> Unit) {
    val pending = connection.error == R.string.approval_required
    GlassCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(28.dp), accent = if (pending) Brand.Amber else Brand.Violet) {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(44.dp).background((if (pending) Brand.Amber else Brand.Violet).copy(alpha = .14f), RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Lock, null, tint = if (pending) Brand.Amber else Brand.Violet)
            }
            Text(stringResource(if (pending) R.string.approval_pending_title else R.string.not_connected_title), style = MaterialTheme.typography.titleLarge)
            Text(stringResource(connection.error ?: R.string.not_connected_detail), color = Brand.Muted, style = MaterialTheme.typography.bodyMedium)
            Button(onClick = onConnect, enabled = !connection.checking, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp), contentPadding = PaddingValues(16.dp)) {
                if (connection.checking) LoadingIndicator(Modifier.size(20.dp), color = Brand.Night)
                else Icon(Icons.Rounded.Sync, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(if (connection.checking) R.string.checking_machine else if (connection.error != null) R.string.retry else R.string.check_connection), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
