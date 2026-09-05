package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ResourceCreation

@Composable
fun CreateResourceDialog(context: CreationContext, saving: Boolean, error: Int?, onDismiss: () -> Unit, onCreate: (ResourceCreation) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var directory by rememberSaveable { mutableStateOf("") }
    var tmux by rememberSaveable { mutableStateOf("") }
    var useSSH by rememberSaveable { mutableStateOf(context.workspace?.isSSH == true) }
    var sourceID by rememberSaveable { mutableStateOf(context.sshSources.firstOrNull()?.id) }
    var sourceMenu by remember { mutableStateOf(false) }
    val existing = context.workspace
    Dialog(onDismissRequest = { if (!saving) onDismiss() }) {
        Surface(shape = RoundedCornerShape(28.dp), color = Brand.Surface) {
            Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()).imePadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(stringResource(if (existing == null) R.string.new_workspace else R.string.new_window), style = MaterialTheme.typography.titleLarge)
                Text(stringResource(if (existing == null) R.string.create_workspace_note else R.string.create_window_note), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
                if (existing == null) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    FilterChip(selected = !useSSH, onClick = { useSSH = false }, label = { Text(stringResource(R.string.local_workspace)) }, enabled = !saving)
                    FilterChip(selected = useSSH, onClick = { useSSH = true }, label = { Text(stringResource(R.string.ssh_workspace)) }, enabled = !saving && context.sshSources.isNotEmpty())
                }
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.resource_name)) }, singleLine = true, enabled = !saving)
                if (existing == null && useSSH) Box {
                    OutlinedButton(onClick = { sourceMenu = true }, enabled = !saving) {
                        Text(context.sshSources.firstOrNull { it.id == sourceID }?.name ?: stringResource(R.string.select_ssh_source))
                    }
                    DropdownMenu(expanded = sourceMenu, onDismissRequest = { sourceMenu = false }) {
                        context.sshSources.forEach { workspace ->
                            DropdownMenuItem(text = { Text(workspace.name) }, onClick = { sourceID = workspace.id; sourceMenu = false })
                        }
                    }
                }
                if (existing != null && useSSH) OutlinedTextField(tmux, { tmux = it }, label = { Text(stringResource(R.string.tmux_session)) }, supportingText = { Text(stringResource(R.string.tmux_session_hint)) }, singleLine = true, enabled = !saving)
                if (existing != null || !useSSH) OutlinedTextField(directory, { directory = it },
                    label = { Text(stringResource(if (existing == null) R.string.working_directory else R.string.optional_directory)) },
                    supportingText = { Text(stringResource(R.string.directory_hint)) }, singleLine = true, enabled = !saving)
                if (existing != null) Text(stringResource(R.string.creation_terminal_agent), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
                if (useSSH) Text(stringResource(R.string.ssh_inherit_note), style = MaterialTheme.typography.bodySmall, color = Brand.Violet)
                error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
                Button(onClick = {
                    val folder = directory.trim().takeIf { it.isNotEmpty() }
                    onCreate(if (existing == null) ResourceCreation.Workspace(name.trim(), if (useSSH) null else folder, if (useSSH) sourceID else null)
                    else ResourceCreation.Terminal(existing.id, name.trim(), folder, if (useSSH) tmux.trim() else null))
                }, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                    if (saving) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    else Text(stringResource(R.string.create))
                }
                TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
            }
        }
    }
}
