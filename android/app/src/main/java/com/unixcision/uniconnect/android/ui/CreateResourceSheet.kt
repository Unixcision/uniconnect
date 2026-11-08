package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Code
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Extension
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.SmartToy
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material.icons.rounded.ViewInAr
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.RemoteAgentTarget
import com.unixcision.uniconnect.android.domain.ResourceCreation
import com.unixcision.uniconnect.android.domain.RunAs

/**
 * Creation sheet for a workspace or a window. In [CreationContext.firstWindow] mode it is the
 * second step of workspace creation: the box already exists and nothing was launched for it.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun CreateResourceSheet(context: CreationContext, saving: Boolean, error: Int?, onDismiss: () -> Unit, onCreate: (ResourceCreation) -> Unit) {
    val existing = context.workspace
    var name by rememberSaveable(context.workspace?.id, context.firstWindow) { mutableStateOf("") }
    var directory by rememberSaveable(context.workspace?.id, context.firstWindow) { mutableStateOf("") }
    var tmux by rememberSaveable(context.workspace?.id) { mutableStateOf("") }
    var useSSH by rememberSaveable(context.workspace?.id) { mutableStateOf(existing?.isSSH == true) }
    var sourceID by rememberSaveable { mutableStateOf(context.sshSources.firstOrNull()?.id) }
    var sourceMenu by remember { mutableStateOf(false) }
    // A new box's SSH connection is either written here or inherited from one the machine holds.
    // Writing is offered only when the machine says it can validate and keep a command; inheriting
    // only when it has one to inherit. With both, writing leads, because someone who opened this
    // form to reach a server it does not know yet has nothing to inherit.
    var writeSSH by rememberSaveable { mutableStateOf(context.sshSources.isEmpty()) }
    var connectCommand by rememberSaveable { mutableStateOf("") }
    var agentID by rememberSaveable(context.machineID, context.workspace?.id) {
        mutableStateOf(existing?.availableAgentTargets?.firstOrNull { it.id == "terminal" }?.id ?: existing?.availableAgentTargets?.firstOrNull()?.id ?: "terminal")
    }
    val selectedAgent = existing?.availableAgentTargets?.firstOrNull { it.id == agentID }
    // «Ejecutar como» (run-as.v1), only for a window of a machine that announces it.
    val offersRunAs = existing != null && context.runsAs
    var runMode by rememberSaveable(context.machineID, context.workspace?.id) { mutableStateOf(RunAs.Mode.CURRENT) }
    var runMethod by rememberSaveable(context.machineID, context.workspace?.id) { mutableStateOf(RunAs.Method.SUDO) }
    var runUser by rememberSaveable(context.machineID, context.workspace?.id) { mutableStateOf("") }
    // Never saveable: saved state outlives the sheet and may reach disk, and the password must not.
    var runPassword by remember(context.machineID, context.workspace?.id) { mutableStateOf("") }
    var sandboxChosen by rememberSaveable(context.machineID, context.workspace?.id) { mutableStateOf(false) }
    val runAs = if (offersRunAs && runMode != RunAs.Mode.CURRENT) {
        RunAs(runMode, runMethod, runUser.trim().takeIf { runMode == RunAs.Mode.USER }, runPassword.takeIf { it.isNotEmpty() })
    } else null
    // IS_SANDBOX only reaches an AI's environment; a plain terminal has nothing to give it to.
    val offersSandbox = offersRunAs && selectedAgent != null && selectedAgent.id != "terminal"
    val sandboxLocked = offersSandbox && RunAs.sandboxLocked(runAs, selectedAgent?.id)
    val isSandbox = offersSandbox && RunAs.sandboxFor(runAs, selectedAgent?.id, sandboxChosen)
    val tone = UniTheme.colors.accent
    ModalBottomSheet(
        onDismissRequest = { if (!saving) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = UniTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = UniTheme.colors.outline) },
    ) {
        Column(Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            when {
                existing == null -> SheetHeader({ Icon(Icons.Rounded.ViewInAr, null, tint = tone) }, stringResource(R.string.new_workspace), stringResource(R.string.create_workspace_note), tone)
                context.firstWindow -> SheetHeader({ Icon(Icons.Rounded.AutoAwesome, null, tint = UniTheme.colors.success) }, stringResource(R.string.first_window_title, existing.name), stringResource(R.string.first_window_note), UniTheme.colors.success)
                else -> SheetHeader({ Icon(Icons.Rounded.Terminal, null, tint = tone) }, stringResource(R.string.new_window), stringResource(R.string.create_window_note), tone)
            }
            if (existing == null) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(selected = !useSSH, onClick = { useSSH = false }, shape = SegmentedButtonDefaults.itemShape(0, 2), enabled = !saving,
                        icon = { Icon(Icons.Rounded.Folder, null, Modifier.size(16.dp)) }, label = { Text(stringResource(R.string.local_workspace)) },
                        colors = segmentColors())
                    SegmentedButton(selected = useSSH, onClick = { useSSH = true }, shape = SegmentedButtonDefaults.itemShape(1, 2), enabled = !saving && context.allowsSSH,
                        icon = { Icon(Icons.Rounded.Language, null, Modifier.size(16.dp)) }, label = { Text(stringResource(R.string.ssh_workspace)) },
                        colors = segmentColors())
                }
                Text(stringResource(if (useSSH) R.string.creation_kind_ssh_note else R.string.creation_kind_local_note), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
            }
            if (existing != null) {
                Text(stringResource(R.string.creation_agent_label), style = MaterialTheme.typography.labelLarge)
                if (existing.availableAgentTargets.isEmpty()) Text(stringResource(R.string.creation_agents_unavailable), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
                else TargetGrid(existing.availableAgentTargets, agentID, enabled = !saving) { agentID = it }
                Text(
                    when {
                        selectedAgent == null -> stringResource(R.string.creation_agent_select)
                        selectedAgent.id == "terminal" -> stringResource(R.string.creation_terminal_agent)
                        else -> stringResource(R.string.creation_agent_note, selectedAgent.title)
                    },
                    style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
                )
            }
            SheetField(name, { name = it }, stringResource(R.string.resource_name), enabled = !saving,
                placeholder = if (existing != null) selectedAgent?.title ?: stringResource(R.string.creation_name_placeholder) else null)
            if (existing == null && useSSH) {
                // Only a machine with both ways to offer needs the choice spelled out.
                if (context.takesNewSSH && context.sshSources.isNotEmpty()) {
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SegmentedButton(selected = writeSSH, onClick = { writeSSH = true }, shape = SegmentedButtonDefaults.itemShape(0, 2), enabled = !saving,
                            label = { Text(stringResource(R.string.ssh_write_connection)) }, colors = segmentColors())
                        SegmentedButton(selected = !writeSSH, onClick = { writeSSH = false }, shape = SegmentedButtonDefaults.itemShape(1, 2), enabled = !saving,
                            label = { Text(stringResource(R.string.ssh_inherit_connection)) }, colors = segmentColors())
                    }
                }
                if (writeSSH && context.takesNewSSH) {
                    SheetField(connectCommand, { connectCommand = it }, stringResource(R.string.ssh_connection_command),
                        hint = stringResource(R.string.ssh_connection_command_hint), enabled = !saving, monospace = true,
                        placeholder = "ssh root@ejemplo.com")
                } else Box {
                    OutlinedButton(onClick = { sourceMenu = true }, enabled = !saving, modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button) {
                        Icon(Icons.Rounded.Language, null, Modifier.size(16.dp), tint = UniTheme.colors.accent); Spacer(Modifier.width(8.dp))
                        Text(context.sshSources.firstOrNull { it.id == sourceID }?.name ?: stringResource(R.string.select_ssh_source))
                    }
                    DropdownMenu(expanded = sourceMenu, onDismissRequest = { sourceMenu = false }, containerColor = UniTheme.colors.surfaceRaised) {
                        context.sshSources.forEach { workspace ->
                            DropdownMenuItem(text = { Text(workspace.name) }, onClick = { sourceID = workspace.id; sourceMenu = false })
                        }
                    }
                }
            }
            if (existing != null && useSSH) SheetField(tmux, { tmux = it }, stringResource(R.string.tmux_session), hint = stringResource(R.string.tmux_session_hint), enabled = !saving, monospace = true)
            if (existing != null || !useSSH) SheetField(directory, { directory = it },
                stringResource(if (existing == null) R.string.working_directory else R.string.optional_directory),
                hint = stringResource(R.string.directory_hint), enabled = !saving, monospace = true, placeholder = "/")
            if (offersRunAs) RunAsSection(
                mode = runMode,
                // Root starts with IS_SANDBOX checked: it is what an AI as root usually needs.
                onMode = { runMode = it; sandboxChosen = it == RunAs.Mode.ROOT },
                method = runMethod, onMethod = { runMethod = it },
                user = runUser, onUser = { runUser = it },
                password = runPassword, onPassword = { runPassword = it },
                offersSandbox = offersSandbox, sandbox = isSandbox, sandboxLocked = sandboxLocked,
                onSandbox = { sandboxChosen = it }, enabled = !saving,
            )
            if (useSSH) Text(
                stringResource(
                    if (existing == null && writeSSH && context.takesNewSSH) R.string.ssh_write_note
                    else R.string.ssh_inherit_note
                ),
                style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
            )
            error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(
                onClick = {
                    val folder = directory.trim().takeIf { it.isNotEmpty() }
                    val visibleName = name.trim().ifEmpty { selectedAgent?.title.orEmpty() }
                    onCreate(
                        if (existing == null) {
                            val typed = if (useSSH && writeSSH && context.takesNewSSH) connectCommand.trim().takeIf { it.isNotEmpty() } else null
                            ResourceCreation.Workspace(
                                name.trim(),
                                if (useSSH) null else folder,
                                if (useSSH && typed == null) sourceID else null,
                                initialTerminal = false,
                                connectCommand = typed,
                            )
                        }
                        // An empty tmux name over SSH lets the machine pick one.
                        else ResourceCreation.Terminal(
                            existing.id, visibleName, folder, if (useSSH) tmux.trim().ifEmpty { null } else null, requireNotNull(selectedAgent).id,
                            runAs = runAs, isSandbox = isSandbox,
                        ),
                    )
                },
                enabled = !saving && (existing == null || selectedAgent != null) && runAs?.isValid() != false,
                modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button, contentPadding = PaddingValues(16.dp),
                colors = ButtonDefaults.buttonColors(containerColor = if (context.firstWindow) UniTheme.colors.success else tone, contentColor = UniTheme.colors.onAccent),
            ) {
                if (saving) LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.onAccent)
                else Text(stringResource(if (existing == null) R.string.create else R.string.new_window), fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(if (context.firstWindow) R.string.not_now else R.string.cancel), color = UniTheme.colors.muted)
            }
        }
    }
}

/**
 * «Ejecutar como»: the connected user, root or another one; for a switch, how (sudo or su) and
 * its password; and whether the AI starts with `IS_SANDBOX=1`. Claude as root cannot start
 * without questions unless it is set, so then the box stays checked and cannot be cleared.
 */
@Composable
private fun RunAsSection(
    mode: RunAs.Mode, onMode: (RunAs.Mode) -> Unit,
    method: RunAs.Method, onMethod: (RunAs.Method) -> Unit,
    user: String, onUser: (String) -> Unit,
    password: String, onPassword: (String) -> Unit,
    offersSandbox: Boolean, sandbox: Boolean, sandboxLocked: Boolean, onSandbox: (Boolean) -> Unit,
    enabled: Boolean,
) {
    Text(stringResource(R.string.run_as_label), style = MaterialTheme.typography.labelLarge)
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        RunAs.Mode.entries.forEachIndexed { index, option ->
            SegmentedButton(
                selected = mode == option, onClick = { onMode(option) }, shape = SegmentedButtonDefaults.itemShape(index, RunAs.Mode.entries.size),
                enabled = enabled, icon = {}, colors = segmentColors(),
                label = {
                    Text(
                        stringResource(when (option) {
                            RunAs.Mode.CURRENT -> R.string.run_as_current
                            RunAs.Mode.ROOT -> R.string.run_as_root
                            RunAs.Mode.USER -> R.string.run_as_user
                        }),
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                },
            )
        }
    }
    if (mode == RunAs.Mode.CURRENT) {
        Text(stringResource(R.string.run_as_current_note), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
    } else {
        if (mode == RunAs.Mode.USER) SheetField(user, onUser, stringResource(R.string.run_as_user_name), enabled = enabled, monospace = true, placeholder = "deploy")
        Text(stringResource(R.string.run_as_method), style = MaterialTheme.typography.labelLarge)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            RunAs.Method.entries.forEachIndexed { index, option ->
                SegmentedButton(
                    selected = method == option, onClick = { onMethod(option) }, shape = SegmentedButtonDefaults.itemShape(index, RunAs.Method.entries.size),
                    enabled = enabled, colors = segmentColors(),
                    label = { Text(stringResource(if (option == RunAs.Method.SUDO) R.string.run_as_sudo else R.string.run_as_su)) },
                )
            }
        }
        Text(
            stringResource(if (mode == RunAs.Mode.ROOT) R.string.run_as_method_note_root else R.string.run_as_method_note_user),
            style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
        )
        SheetField(password, onPassword, stringResource(R.string.run_as_password), hint = stringResource(R.string.run_as_password_hint), enabled = enabled, secret = true)
    }
    if (offersSandbox) Row(
        Modifier.fillMaxWidth().clip(UniTheme.shapes.chip)
            .toggleable(value = sandbox, enabled = enabled && !sandboxLocked, role = Role.Checkbox, onValueChange = onSandbox)
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Checkbox(
            checked = sandbox, onCheckedChange = null, enabled = enabled && !sandboxLocked,
            colors = CheckboxDefaults.colors(checkedColor = UniTheme.colors.accent, uncheckedColor = UniTheme.colors.muted, checkmarkColor = UniTheme.colors.onAccent),
        )
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.run_as_sandbox), style = MaterialTheme.typography.labelLarge, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
            Text(
                stringResource(if (sandboxLocked) R.string.run_as_sandbox_locked else R.string.run_as_sandbox_note),
                style = MaterialTheme.typography.bodySmall, color = if (sandboxLocked) UniTheme.colors.warning else UniTheme.colors.muted,
            )
        }
    }
}

@Composable
private fun segmentColors() = SegmentedButtonDefaults.colors(
    activeContainerColor = UniTheme.colors.accent.copy(alpha = .18f), activeContentColor = UniTheme.colors.accent, activeBorderColor = UniTheme.colors.accent.copy(alpha = .5f),
    inactiveContainerColor = Color.Transparent, inactiveContentColor = UniTheme.colors.muted, inactiveBorderColor = UniTheme.colors.outline,
)

/** Two-column cards for the host's launch catalogue; the IDs are opaque and sent back unchanged. */
@Composable
private fun TargetGrid(targets: List<RemoteAgentTarget>, selectedID: String, enabled: Boolean, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        targets.chunked(2).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { target -> TargetCard(target, target.id == selectedID, enabled, Modifier.weight(1f)) { onSelect(target.id) } }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TargetCard(target: RemoteAgentTarget, selected: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val (icon, tone) = targetPresentation(target.id)
    val shape = UniTheme.shapes.button
    Row(
        modifier.background(if (selected) tone.copy(alpha = .14f) else UniTheme.colors.surfaceRaised.copy(alpha = .4f), shape)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) tone.copy(alpha = .7f) else UniTheme.colors.outline, shape)
            .clickable(enabled = enabled, onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, null, Modifier.size(22.dp), tint = if (selected) tone else UniTheme.colors.muted)
        Column(Modifier.weight(1f)) {
            Text(target.title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (selected) UniTheme.colors.text else UniTheme.colors.muted)
            Text(stringResource(if (target.id == "terminal") R.string.creation_target_terminal_summary else R.string.creation_target_agent_summary),
                style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (selected) Icon(Icons.Rounded.CheckCircle, null, Modifier.size(18.dp), tint = tone)
    }
}

@Composable
private fun targetPresentation(id: String): Pair<ImageVector, Color> = when {
    id == "terminal" -> Icons.Rounded.Terminal to UniTheme.colors.accent
    id == "claude" -> Icons.Rounded.AutoAwesome to UniTheme.colors.warning
    id == "codex" -> Icons.Rounded.Code to UniTheme.colors.success
    id == "agy" -> Icons.Rounded.Explore to UniTheme.colors.accent
    id == "grok" -> Icons.Rounded.Bolt to UniTheme.colors.danger
    id.startsWith("custom") -> Icons.Rounded.SmartToy to UniTheme.colors.accent
    else -> Icons.Rounded.Extension to UniTheme.colors.muted
}
