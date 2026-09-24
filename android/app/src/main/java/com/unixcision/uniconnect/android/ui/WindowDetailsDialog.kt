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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DetailsLineKind
import com.unixcision.uniconnect.android.domain.DetailsText
import com.unixcision.uniconnect.android.domain.WindowDetails
import com.unixcision.uniconnect.android.domain.WindowDetailsRows
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * «Detalles» de una ventana: dónde vive, qué tmux la sostiene, qué IA corre y cómo reanudarla.
 *
 * Las mismas filas, en el mismo orden y con el mismo texto que el modal del Mac y de Linux
 * (`contracts/window-details-v1`): las arma [WindowDetailsRows] y aquí solo se pintan.
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
    val context = LocalContext.current
    // Las filas salen del mismo renderizador que se prueba contra contracts/window-details-v1/filas.json.
    val sheet = remember(details, context) { WindowDetailsRows.render(details) { text -> context.getString(text.stringRes) } }
    Column(
        Modifier.fillMaxWidth().heightIn(max = 460.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Si el equipo no pudo mirar ahora, se dice antes que nada: todo lo de abajo es lo guardado.
        sheet.notice?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning) }
        sheet.lines.forEach { line ->
            if (line.kind == DetailsLineKind.COMMAND) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(line.label, style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
                    // Seleccionable además de copiable: a veces solo se quiere un trozo, como el id.
                    SelectionContainer {
                        Text(line.value, fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp, color = UniTheme.colors.text)
                    }
                    sheet.commandNote?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning) }
                    if (copied) {
                        Text(stringResource(R.string.details_copied), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.accent)
                    }
                }
            } else {
                DetailsRow(line.label, line.value, monospace = line.kind == DetailsLineKind.CODE)
            }
        }
    }
}

@Composable
private fun DetailsRow(label: String, value: String, monospace: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
        SelectionContainer {
            Text(
                value,
                style = if (monospace) MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace) else MaterialTheme.typography.bodyMedium,
                color = UniTheme.colors.text,
            )
        }
    }
}

/** El recurso de cada texto del modal. Exhaustivo: un texto nuevo sin recurso no compila. */
private val DetailsText.stringRes: Int
    get() = when (this) {
        DetailsText.WORKSPACE -> R.string.details_workspace
        DetailsText.KIND -> R.string.details_kind
        DetailsText.KIND_LOCAL -> R.string.details_kind_local
        DetailsText.KIND_SSH -> R.string.details_kind_ssh
        DetailsText.KIND_SSH_UNNAMED -> R.string.details_kind_ssh_unnamed
        DetailsText.WINDOW -> R.string.details_window
        DetailsText.TMUX_SOCKET -> R.string.details_tmux_socket
        DetailsText.TMUX_DEFAULT -> R.string.details_tmux_default
        DetailsText.TMUX_SESSION -> R.string.details_tmux_session
        DetailsText.TMUX_NONE -> R.string.details_tmux_none
        DetailsText.TMUX_IDS_LABEL -> R.string.details_tmux_ids_label
        DetailsText.TMUX_IDS -> R.string.details_tmux_ids
        DetailsText.TMUX_NOT_LIVE -> R.string.details_tmux_not_live
        DetailsText.TMUX_UNCHECKED -> R.string.details_tmux_unchecked
        DetailsText.AGENT -> R.string.details_agent
        DetailsText.AGENT_AMBIGUOUS -> R.string.details_agent_ambiguous
        DetailsText.AGENT_NONE_SAVED -> R.string.details_agent_none_saved
        DetailsText.AGENT_NONE -> R.string.details_agent_none
        DetailsText.AGENT_NO_ID_LIVE -> R.string.details_agent_no_id_live
        DetailsText.AGENT_NO_ID_SAVED -> R.string.details_agent_no_id_saved
        DetailsText.STATE -> R.string.details_state
        DetailsText.STATE_ACTIVE -> R.string.details_state_active
        DetailsText.STATE_INTERRUPTED -> R.string.details_state_interrupted
        DetailsText.STATE_SAVED_SHELL -> R.string.details_state_saved_shell
        DetailsText.STATE_SAVED -> R.string.details_state_saved
        DetailsText.SESSION -> R.string.details_session
        DetailsText.CWD -> R.string.details_cwd
        DetailsText.AS_ROOT -> R.string.details_as_root
        DetailsText.YES -> R.string.details_yes
        DetailsText.NO -> R.string.details_no
        DetailsText.SOURCE -> R.string.details_source
        DetailsText.SOURCE_FICHA -> R.string.details_source_ficha
        DetailsText.SOURCE_ROLLOUT -> R.string.details_source_rollout
        DetailsText.SOURCE_ARGV -> R.string.details_source_argv
        DetailsText.SOURCE_HOOK -> R.string.details_source_hook
        DetailsText.SOURCE_MANIFIESTO -> R.string.details_source_manifiesto
        DetailsText.SOURCE_REGISTRO -> R.string.details_source_registro
        DetailsText.RESUME -> R.string.details_resume
        DetailsText.NO_PROMPT_UNVERIFIED -> R.string.details_no_prompt_unverified
        DetailsText.UNREACHABLE_SSH -> R.string.details_host_unreachable
        DetailsText.UNREACHABLE_LOCAL -> R.string.details_host_unreachable_local
        DetailsText.EMPTY -> R.string.details_empty
    }
