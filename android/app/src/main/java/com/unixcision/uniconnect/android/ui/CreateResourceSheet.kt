package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.RemoteAgentTarget
import com.unixcision.uniconnect.android.domain.ResourceCreation

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
    var agentID by rememberSaveable(context.machineID, context.workspace?.id) {
        mutableStateOf(existing?.availableAgentTargets?.firstOrNull { it.id == "terminal" }?.id ?: existing?.availableAgentTargets?.firstOrNull()?.id ?: "terminal")
    }
    val selectedAgent = existing?.availableAgentTargets?.firstOrNull { it.id == agentID }
    val tone = if (useSSH) Brand.Violet else Brand.Cyan
    ModalBottomSheet(
        onDismissRequest = { if (!saving) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Brand.Surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Brand.Outline) },
    ) {
        Column(Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            when {
                existing == null -> SheetHeader({ Icon(Icons.Rounded.ViewInAr, null, tint = tone) }, stringResource(R.string.new_workspace), stringResource(R.string.create_workspace_note), tone)
                context.firstWindow -> SheetHeader({ Icon(Icons.Rounded.AutoAwesome, null, tint = Brand.Mint) }, stringResource(R.string.first_window_title, existing.name), stringResource(R.string.first_window_note), Brand.Mint)
                else -> SheetHeader({ Icon(Icons.Rounded.Terminal, null, tint = tone) }, stringResource(R.string.new_window), stringResource(R.string.create_window_note), tone)
            }
            if (existing == null) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(selected = !useSSH, onClick = { useSSH = false }, shape = SegmentedButtonDefaults.itemShape(0, 2), enabled = !saving,
                        icon = { Icon(Icons.Rounded.Folder, null, Modifier.size(16.dp)) }, label = { Text(stringResource(R.string.local_workspace)) },
                        colors = segmentColors())
                    SegmentedButton(selected = useSSH, onClick = { useSSH = true }, shape = SegmentedButtonDefaults.itemShape(1, 2), enabled = !saving && context.sshSources.isNotEmpty(),
                        icon = { Icon(Icons.Rounded.Language, null, Modifier.size(16.dp)) }, label = { Text(stringResource(R.string.ssh_workspace)) },
                        colors = segmentColors())
                }
                Text(stringResource(if (useSSH) R.string.creation_kind_ssh_note else R.string.creation_kind_local_note), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
            }
            if (existing != null) {
                Text(stringResource(R.string.creation_agent_label), style = MaterialTheme.typography.labelLarge)
                if (existing.availableAgentTargets.isEmpty()) Text(stringResource(R.string.creation_agents_unavailable), style = MaterialTheme.typography.bodySmall, color = Brand.Amber)
                else TargetGrid(existing.availableAgentTargets, agentID, enabled = !saving) { agentID = it }
                Text(
                    when {
                        selectedAgent == null -> stringResource(R.string.creation_agent_select)
                        selectedAgent.id == "terminal" -> stringResource(R.string.creation_terminal_agent)
                        else -> stringResource(R.string.creation_agent_note, selectedAgent.title)
                    },
                    style = MaterialTheme.typography.bodySmall, color = Brand.Muted,
                )
            }
            SheetField(name, { name = it }, stringResource(R.string.resource_name), enabled = !saving,
                placeholder = if (existing != null) selectedAgent?.title ?: stringResource(R.string.creation_name_placeholder) else null)
            if (existing == null && useSSH) Box {
                OutlinedButton(onClick = { sourceMenu = true }, enabled = !saving, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(16.dp)) {
                    Icon(Icons.Rounded.Language, null, Modifier.size(16.dp), tint = Brand.Violet); Spacer(Modifier.width(8.dp))
                    Text(context.sshSources.firstOrNull { it.id == sourceID }?.name ?: stringResource(R.string.select_ssh_source))
                }
                DropdownMenu(expanded = sourceMenu, onDismissRequest = { sourceMenu = false }, containerColor = Brand.SurfaceHigh) {
                    context.sshSources.forEach { workspace ->
                        DropdownMenuItem(text = { Text(workspace.name) }, onClick = { sourceID = workspace.id; sourceMenu = false })
                    }
                }
            }
            if (existing != null && useSSH) SheetField(tmux, { tmux = it }, stringResource(R.string.tmux_session), hint = stringResource(R.string.tmux_session_hint), enabled = !saving, monospace = true)
            if (existing != null || !useSSH) SheetField(directory, { directory = it },
                stringResource(if (existing == null) R.string.working_directory else R.string.optional_directory),
                hint = stringResource(R.string.directory_hint), enabled = !saving, monospace = true, placeholder = "/")
            if (useSSH) Text(stringResource(R.string.ssh_inherit_note), style = MaterialTheme.typography.bodySmall, color = Brand.Violet)
            error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(
                onClick = {
                    val folder = directory.trim().takeIf { it.isNotEmpty() }
                    val visibleName = name.trim().ifEmpty { selectedAgent?.title.orEmpty() }
                    onCreate(
                        if (existing == null) ResourceCreation.Workspace(name.trim(), if (useSSH) null else folder, if (useSSH) sourceID else null, initialTerminal = false)
                        else ResourceCreation.Terminal(existing.id, visibleName, folder, if (useSSH) tmux.trim() else null, requireNotNull(selectedAgent).id),
                    )
                },
                enabled = !saving && (existing == null || selectedAgent != null),
                modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp), contentPadding = PaddingValues(16.dp),
                colors = ButtonDefaults.buttonColors(containerColor = if (context.firstWindow) Brand.Mint else tone, contentColor = Brand.Night),
            ) {
                if (saving) LoadingIndicator(Modifier.size(20.dp), color = Brand.Night)
                else Text(stringResource(if (existing == null) R.string.create else R.string.new_window), fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(if (context.firstWindow) R.string.not_now else R.string.cancel), color = Brand.Muted)
            }
        }
    }
}

@Composable
private fun segmentColors() = SegmentedButtonDefaults.colors(
    activeContainerColor = Brand.Cyan.copy(alpha = .18f), activeContentColor = Brand.Cyan, activeBorderColor = Brand.Cyan.copy(alpha = .5f),
    inactiveContainerColor = Color.Transparent, inactiveContentColor = Brand.Muted, inactiveBorderColor = Brand.Outline,
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
    val shape = RoundedCornerShape(16.dp)
    Row(
        modifier.background(if (selected) tone.copy(alpha = .14f) else Brand.DeepBlue.copy(alpha = .4f), shape)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) tone.copy(alpha = .7f) else Brand.Outline, shape)
            .clickable(enabled = enabled, onClick = onClick).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, null, Modifier.size(22.dp), tint = if (selected) tone else Brand.Muted)
        Column(Modifier.weight(1f)) {
            Text(target.title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (selected) Brand.Text else Brand.Muted)
            Text(stringResource(if (target.id == "terminal") R.string.creation_target_terminal_summary else R.string.creation_target_agent_summary),
                style = MaterialTheme.typography.labelSmall, color = Brand.Muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        if (selected) Icon(Icons.Rounded.CheckCircle, null, Modifier.size(18.dp), tint = tone)
    }
}

private fun targetPresentation(id: String): Pair<ImageVector, Color> = when {
    id == "terminal" -> Icons.Rounded.Terminal to Brand.Cyan
    id == "claude" -> Icons.Rounded.AutoAwesome to Brand.Amber
    id == "codex" -> Icons.Rounded.Code to Brand.Mint
    id == "agy" -> Icons.Rounded.Explore to Brand.Violet
    id == "grok" -> Icons.Rounded.Bolt to Brand.Coral
    id.startsWith("custom") -> Icons.Rounded.SmartToy to Brand.Violet
    else -> Icons.Rounded.Extension to Brand.Muted
}
