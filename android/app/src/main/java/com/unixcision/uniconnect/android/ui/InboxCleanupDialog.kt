package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import kotlinx.coroutines.delay

/**
 * Liberar espacio en la bandeja de un equipo: todo, lo anterior a un tiempo, lo mayor de un
 * tamaño (o las dos cosas a la vez, y entonces solo lo que cumpla ambas). Cada cambio se simula
 * en el equipo y el botón dice exactamente cuántos archivos y cuántos megas se van; hasta que el
 * cálculo coincide con lo marcado, no se puede borrar.
 */
@Composable
internal fun InboxCleanupDialog(inbox: InboxViewModel, machine: Machine, onDismiss: () -> Unit) {
    val state by inbox.state.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    var everything by remember { mutableStateOf(false) }
    var byAge by remember { mutableStateOf(true) }
    var days by remember { mutableIntStateOf(30) }
    var bySize by remember { mutableStateOf(false) }
    var bytes by remember { mutableLongStateOf(20L * MB) }
    var started by remember { mutableStateOf(false) }
    val deletion = when {
        everything -> InboxDeletion(everything = true)
        else -> InboxDeletion(olderThanDays = days.takeIf { byAge }, largerThanBytes = bytes.takeIf { bySize })
    }
    // Un aviso de un borrado anterior (de un solo archivo, por ejemplo) no es de este diálogo.
    LaunchedEffect(Unit) { inbox.dismissRemoval(machine) }
    // Se espera un momento a que se deje de tocar antes de preguntar al equipo.
    LaunchedEffect(deletion) {
        if (started) return@LaunchedEffect
        delay(250)
        inbox.estimate(machine, deletion)
    }
    val estimate = state.estimates[machine.id]?.takeIf { it.deletion == deletion.copy(dryRun = true) }
    val removal = state.removals[machine.id]?.takeIf { started }
    AlertDialog(
        onDismissRequest = { if (removal?.running != true) { inbox.dismissRemoval(machine); onDismiss() } },
        containerColor = colors.surface,
        title = { Text(stringResource(R.string.inbox_cleanup_title, machine.name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (removal != null) {
                    when {
                        removal.running -> Text(stringResource(R.string.inbox_cleanup_running), color = colors.muted)
                        removal.failure != null -> Text(removal.failure.inboxMessage(machine.name), color = colors.danger)
                        removal.result != null -> Text(
                            stringResource(R.string.inbox_cleanup_done, inboxFiles(removal.result.deleted), formatSize(removal.result.freedBytes)),
                            color = colors.success, fontWeight = FontWeight.SemiBold,
                        )
                    }
                    return@Column
                }
                Text(stringResource(R.string.inbox_cleanup_note), style = MaterialTheme.typography.bodySmall, color = colors.muted)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.inbox_cleanup_everything), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Switch(
                        checked = everything, onCheckedChange = { everything = it },
                        colors = SwitchDefaults.colors(checkedTrackColor = colors.danger, checkedThumbColor = colors.onAccent),
                    )
                }
                Criterion(stringResource(R.string.inbox_cleanup_older), byAge && !everything, enabled = !everything, onToggle = { byAge = it }) {
                    AGES.forEach { (value, label) -> ServiceChip(stringResource(label), selected = byAge && days == value) { days = value; byAge = true } }
                }
                Criterion(stringResource(R.string.inbox_cleanup_larger), bySize && !everything, enabled = !everything, onToggle = { bySize = it }) {
                    SIZES.forEach { value -> ServiceChip("${value / MB} MB", selected = bySize && bytes == value) { bytes = value; bySize = true } }
                }
                val result = estimate?.result
                Text(
                    when {
                        !deletion.hasCriterion -> stringResource(R.string.inbox_cleanup_pick)
                        estimate?.failure != null -> estimate.failure.inboxMessage(machine.name)
                        result == null -> stringResource(R.string.inbox_cleanup_estimating)
                        result.deleted == 0 -> stringResource(R.string.inbox_cleanup_nothing)
                        else -> stringResource(
                            R.string.inbox_cleanup_estimate,
                            inboxFiles(result.deleted), formatSize(result.freedBytes), inboxFiles(result.remainingCount), formatSize(result.remainingBytes),
                        )
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (estimate?.failure != null) colors.danger else colors.text,
                )
            }
        },
        confirmButton = {
            val result = estimate?.result
            when {
                removal != null -> if (!removal.running) TextButton(onClick = { inbox.dismissRemoval(machine); onDismiss() }) { Text(stringResource(R.string.close)) }
                else -> Button(
                    onClick = { started = true; inbox.delete(machine, deletion) },
                    enabled = result != null && result.deleted > 0,
                    colors = ButtonDefaults.buttonColors(containerColor = colors.danger, contentColor = colors.onAccent),
                    shape = UniTheme.shapes.button,
                ) { Text(stringResource(R.string.inbox_cleanup_confirm, inboxFiles(result?.deleted ?: 0)), fontWeight = FontWeight.SemiBold) }
            }
        },
        dismissButton = {
            if (removal == null) TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel), color = colors.muted) }
        },
    )
}

/** Una casilla para activar el criterio (se toca la fila entera) y sus opciones como chips; tocar un chip ya lo activa. */
@Composable
private fun Criterion(title: String, checked: Boolean, enabled: Boolean, onToggle: (Boolean) -> Unit, options: @Composable () -> Unit) {
    val colors = UniTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            Modifier.fillMaxWidth().toggleable(value = checked, enabled = enabled, role = Role.Checkbox, onValueChange = onToggle),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Checkbox(
                checked = checked, onCheckedChange = null, enabled = enabled,
                colors = CheckboxDefaults.colors(checkedColor = colors.accent, uncheckedColor = colors.outline),
            )
            Text(title, style = MaterialTheme.typography.bodyMedium, color = if (enabled) colors.text else colors.muted)
        }
        if (enabled) Row(Modifier.fillMaxWidth().padding(start = 12.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            options()
        }
    }
}

private const val MB = 1024L * 1024
private val AGES = listOf(1 to R.string.inbox_cleanup_day, 7 to R.string.inbox_cleanup_week, 30 to R.string.inbox_cleanup_month, 90 to R.string.inbox_cleanup_quarter)
private val SIZES = listOf(5 * MB, 20 * MB, 100 * MB, 500 * MB)
