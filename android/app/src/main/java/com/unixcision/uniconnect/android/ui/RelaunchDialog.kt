package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.RelaunchTargetState
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Enseña un relanzado antes, durante y después.
 *
 * Después se enseña siempre, también cuando todo fue bien: tras reiniciar veintiséis agentes,
 * «no ha saltado nada» no es lo mismo que saber que volvieron los veintiséis.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RelaunchDialog(state: RelaunchUI, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    when (state) {
        is RelaunchUI.Confirm -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(R.string.relaunch_confirm_title, state.plan.targets.size)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.relaunch_confirm_note), style = MaterialTheme.typography.bodyMedium)
                    // Se nombran unas cuantas: una cifra sola no deja comprobar que son las que uno
                    // creía, y aquí el coste de equivocarse es reiniciar el agente de otro.
                    state.plan.targets.take(6).forEach {
                        Text("· ${it.label}", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
                    }
                    if (state.plan.targets.size > 6) {
                        Text("· …", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
                    }
                    if (state.plan.exclusions.isNotEmpty()) {
                        Text(
                            stringResource(R.string.relaunch_confirm_excluded, state.plan.exclusions.size),
                            style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning,
                        )
                    }
                }
            },
            confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.relaunch_go)) } },
            dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
            containerColor = UniTheme.colors.surface,
        )

        is RelaunchUI.Running -> AlertDialog(
            // Sin botón de cerrar a propósito: el equipo ya lo aceptó y cerrar esto no lo detendría.
            onDismissRequest = {},
            title = { Text(stringResource(R.string.relaunch_running, state.total)) },
            text = { LoadingIndicator(Modifier.size(28.dp), color = UniTheme.colors.accent) },
            confirmButton = {},
            containerColor = UniTheme.colors.surface,
        )

        is RelaunchUI.Done -> {
            val verified = state.operation.results.count { it.state == RelaunchTargetState.VERIFIED }
            AlertDialog(
                onDismissRequest = onDismiss,
                title = { Text(stringResource(R.string.relaunch_done_title, verified, state.operation.results.size)) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (state.operation.needingUser.isNotEmpty()) {
                            Text(
                                stringResource(R.string.relaunch_needs_user, state.operation.needingUser.size),
                                style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.warning,
                            )
                        }
                        if (state.operation.retryable.isNotEmpty()) {
                            Text(
                                stringResource(R.string.relaunch_failed_some, state.operation.retryable.size),
                                style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.danger,
                            )
                        }
                    }
                },
                confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
                containerColor = UniTheme.colors.surface,
            )
        }

        is RelaunchUI.Failed -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(R.string.relaunch_agents)) },
            text = { Text(stringResource(state.message), style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
            containerColor = UniTheme.colors.surface,
        )
    }
}
