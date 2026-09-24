package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DetailsAgentState
import com.unixcision.uniconnect.android.domain.DetailsReason
import com.unixcision.uniconnect.android.domain.DetailsSource
import com.unixcision.uniconnect.android.domain.WindowDetails
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * «Detalles» de una ventana: dónde vive, qué tmux la sostiene, qué IA corre y cómo reanudarla.
 *
 * Las mismas filas y en el mismo orden que el modal del Mac y de Linux
 * (`contracts/window-details-v1`), para que el mismo dato se lea igual en los tres sitios.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun WindowDetailsDialog(state: WindowDetailsUI, onCopy: () -> Unit, onDismiss: () -> Unit) {
    val ready = state as? WindowDetailsUI.Ready
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.details_title)) },
        text = {
            when (state) {
                is WindowDetailsUI.Loading -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    LoadingIndicator(Modifier.size(28.dp), color = UniTheme.colors.accent)
                    Text(stringResource(R.string.details_loading), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
                }
                is WindowDetailsUI.Failed -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(state.message), style = MaterialTheme.typography.bodyMedium)
                    state.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted) }
                }
                is WindowDetailsUI.Ready -> DetailsRows(state.details, state.copied)
            }
        },
        confirmButton = {
            // «Copiar orden» solo cuando hay una orden que copiar.
            if (ready?.details?.agent?.resume != null) {
                TextButton(onClick = onCopy) { Text(stringResource(R.string.details_copy)) }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.details_close)) }
            }
        },
        dismissButton = {
            if (ready?.details?.agent?.resume != null) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.details_close)) }
            }
        },
        containerColor = UniTheme.colors.surface,
    )
}

@Composable
private fun DetailsRows(details: WindowDetails, copied: Boolean) {
    Column(
        Modifier.fillMaxWidth().heightIn(max = 460.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Si el equipo no pudo mirar ahora, se dice antes que nada: todo lo de abajo es lo guardado.
        if (details.reasonKind == DetailsReason.HOST_UNREACHABLE) {
            Text(stringResource(R.string.details_host_unreachable), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
        }
        DetailsRow(R.string.details_workspace, details.workspaceName)
        DetailsRow(
            R.string.details_kind,
            if (details.isSSH) {
                details.hostDescription?.let { stringResource(R.string.details_kind_ssh, it) } ?: stringResource(R.string.details_kind_ssh_unnamed)
            } else {
                stringResource(R.string.details_kind_local)
            },
        )
        DetailsRow(R.string.details_window, details.windowName)
        val tmux = details.tmux
        if (tmux == null) {
            DetailsRow(R.string.details_tmux_socket, stringResource(R.string.details_tmux_none))
        } else {
            DetailsRow(R.string.details_tmux_socket, if (tmux.isDefaultServer) stringResource(R.string.details_tmux_default) else tmux.socket)
            DetailsRow(R.string.details_tmux_session, tmux.session)
            DetailsRow(
                R.string.details_tmux_ids_label,
                if (tmux.live && tmux.sessionID != null && tmux.paneID != null) {
                    stringResource(R.string.details_tmux_ids, tmux.sessionID, tmux.paneID)
                } else {
                    stringResource(R.string.details_tmux_not_live)
                },
            )
        }
        val agent = details.agent
        DetailsRow(
            R.string.details_agent,
            when {
                agent == null && details.reasonKind == DetailsReason.AMBIGUOUS -> stringResource(R.string.details_agent_ambiguous)
                agent == null -> stringResource(R.string.details_agent_none)
                agent.sessionID == null -> agent.name + " · " + stringResource(R.string.details_agent_no_id)
                else -> agent.name
            },
        )
        if (agent != null) {
            DetailsRow(
                R.string.details_state,
                when (agent.stateKind) {
                    DetailsAgentState.ACTIVE -> stringResource(R.string.details_state_active)
                    DetailsAgentState.SAVED -> stringResource(R.string.details_state_saved)
                    DetailsAgentState.INTERRUPTED -> stringResource(R.string.details_state_interrupted)
                    // Un estado que esta versión no conoce se enseña crudo, no se esconde.
                    null -> agent.state ?: "—"
                },
            )
            agent.sessionID?.let { DetailsRow(R.string.details_session, it, monospace = true) }
            agent.cwd?.let { DetailsRow(R.string.details_cwd, it, monospace = true) }
            if (details.isSSH && agent.asRoot != null) {
                DetailsRow(R.string.details_as_root, stringResource(if (agent.asRoot) R.string.details_yes else R.string.details_no))
            }
            agent.source?.let { source ->
                DetailsRow(
                    R.string.details_source,
                    when (agent.sourceKind) {
                        DetailsSource.SESSION_FILE -> stringResource(R.string.details_source_ficha)
                        DetailsSource.ROLLOUT -> stringResource(R.string.details_source_rollout)
                        DetailsSource.ARGV -> stringResource(R.string.details_source_argv)
                        DetailsSource.HOOK -> stringResource(R.string.details_source_hook)
                        DetailsSource.MANIFEST -> stringResource(R.string.details_source_manifiesto)
                        DetailsSource.RECORD -> stringResource(R.string.details_source_registro)
                        null -> source
                    },
                )
            }
            agent.resume?.let { resume ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(stringResource(R.string.details_resume), style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
                    // Seleccionable además de copiable: a veces solo se quiere un trozo, como el id.
                    SelectionContainer {
                        Text(resume.command, fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp, color = UniTheme.colors.text)
                    }
                    if (!resume.noPromptVerified) {
                        Text(stringResource(R.string.details_no_prompt_unverified), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
                    }
                    if (copied) {
                        Text(stringResource(R.string.details_copied), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.accent)
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailsRow(label: Int, value: String, monospace: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(stringResource(label), style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
        SelectionContainer {
            Text(
                value.ifEmpty { "—" },
                style = if (monospace) MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace) else MaterialTheme.typography.bodyMedium,
                color = UniTheme.colors.text,
            )
        }
    }
}
