package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.RelaunchScope
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import com.unixcision.uniconnect.android.ui.design.DesignedMachine
import com.unixcision.uniconnect.android.ui.design.MachineActions
import com.unixcision.uniconnect.android.ui.design.MachineModel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * One machine: every workspace with its windows, drawn by the design in force.
 *
 * This is the part every design shares: the model built from the connection and the phone's own
 * favourites, and the long-press sheet (favourite, order, relaunch) for a workspace or a window.
 */
@Composable
fun MachineBoxesScreen(
    machine: Machine,
    connection: MachinesViewModel.Connection,
    /** The workspace to bring into view: the one a notice named or the one of the window just closed. */
    focusWorkspaceID: String?,
    noticeLink: NotificationLinkState?,
    overrides: BoxOverrides,
    hostKeepsOrder: Boolean?,
    onBack: () -> Unit,
    onEnableNotices: () -> Unit,
    onDisableNotices: () -> Unit,
    onConnect: () -> Unit,
    onCreateWorkspace: () -> Unit,
    onCreateWindow: (workspaceID: String) -> Unit,
    onOpenWindow: (workspaceID: String, windowID: String) -> Unit,
    onToggleWorkspacePin: (String) -> Unit,
    onToggleWindowPin: (windowID: String, workspaceID: String) -> Unit,
    onMoveWorkspace: (String, Int) -> Unit,
    onMoveWindow: (windowID: String, delta: Int, workspaceID: String) -> Unit,
    /**
     * Relanza las IA de un alcance. Nulo cuando el equipo no anuncia `relaunch.v1`: la acción no se
     * enseña en vez de enseñarse y no hacer nada.
     */
    onRelaunch: ((RelaunchScope) -> Unit)?,
    menu: @Composable () -> Unit,
) {
    val model = remember(machine, connection, overrides, hostKeepsOrder, noticeLink, focusWorkspaceID) {
        MachineModel.of(machine, connection, overrides, hostKeepsOrder, noticeLink, focusWorkspaceID)
    }
    val snapshot = connection.snapshot
    // A long press opens the same sheet for either kind; which one is held here, by id, so a
    // refreshed list never leaves the sheet acting on a stale copy.
    var heldWorkspace by remember { mutableStateOf<String?>(null) }
    var heldWindow by remember { mutableStateOf<Pair<String, String>?>(null) }
    heldWorkspace?.let { id -> snapshot?.workspaces?.firstOrNull { it.id == id } }?.let { held ->
        BoxActionsSheet(held.name, R.string.box_actions_workspace, held.isPinned || held.id in overrides.pinnedWorkspaces,
            onTogglePin = { onToggleWorkspacePin(held.id) }, onMoveTop = { onMoveWorkspace(held.id, Int.MIN_VALUE) },
            onMoveUp = { onMoveWorkspace(held.id, -1) }, onMoveDown = { onMoveWorkspace(held.id, 1) }, onDismiss = { heldWorkspace = null },
            onRelaunch = onRelaunch?.let { relaunch -> { relaunch(RelaunchScope.Workspace(machine.id, held.id)) } })
    }
    heldWindow?.let { (workspaceID, windowID) ->
        val workspace = snapshot?.workspaces?.firstOrNull { it.id == workspaceID }
        workspace?.windows?.firstOrNull { it.id == windowID }?.let { held -> workspace to held }
    }?.let { (workspace, held) ->
        BoxActionsSheet(held.name, R.string.box_actions_window, held.isPinned || held.id in overrides.pinnedWindows,
            onTogglePin = { onToggleWindowPin(held.id, workspace.id) }, onMoveTop = { onMoveWindow(held.id, Int.MIN_VALUE, workspace.id) },
            onMoveUp = { onMoveWindow(held.id, -1, workspace.id) }, onMoveDown = { onMoveWindow(held.id, 1, workspace.id) }, onDismiss = { heldWindow = null },
            // Una ventana sola: solo si el equipo sabe relanzar su IA en ese tipo de ventana (D7).
            onRelaunch = onRelaunch?.takeIf { snapshot?.relaunchesWindow(workspace.isSSH, held.activity?.agent) == true }?.let { relaunch ->
                { relaunch(RelaunchScope.Window(machine.id, workspace.id, held.id)) }
            })
    }
    val actions = MachineActions(
        onBack = onBack, onConnect = onConnect, onEnableNotices = onEnableNotices, onDisableNotices = onDisableNotices,
        onCreateWorkspace = onCreateWorkspace, onCreateWindow = onCreateWindow, onOpenWindow = onOpenWindow,
        onToggleWorkspacePin = onToggleWorkspacePin,
        onHoldWorkspace = { heldWorkspace = it }, onHoldWindow = { workspaceID, windowID -> heldWindow = workspaceID to windowID },
    )
    DesignedMachine(model, actions, menu)
}

@Composable
fun KindBadge(workspace: RemoteWorkspace) {
    val (label, color) = when (workspace.isSSH) {
        true -> R.string.box_ssh_badge to UniTheme.colors.accent
        false -> R.string.box_local_badge to UniTheme.colors.muted
        null -> R.string.box_unknown_badge to UniTheme.colors.muted
    }
    Text(stringResource(label), Modifier.background(color.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
        style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.Bold)
}
