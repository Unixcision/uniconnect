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
import com.unixcision.uniconnect.android.domain.RelaunchCause
import com.unixcision.uniconnect.android.domain.RelaunchReason
import com.unixcision.uniconnect.android.domain.RelaunchReasons
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
            title = {
                Text(
                    if (state.plan.actionable) {
                        stringResource(R.string.relaunch_confirm_title, state.plan.targets.size)
                    } else {
                        stringResource(R.string.relaunch_unavailable_title)
                    }
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    // Si el equipo ya ha dicho que no puede, se dice aquí y no después de pulsar.
                    state.plan.unavailableReason?.let { reason ->
                        Text(reason, style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.warning)
                    }
                    if (state.plan.actionable) {
                        Text(stringResource(R.string.relaunch_confirm_note), style = MaterialTheme.typography.bodyMedium)
                    }
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
            // Sin nada que hacer no se ofrece «Adelante»: un botón que no va a hacer nada es
            // peor que no tenerlo, porque quien lo pulsa se queda esperando.
            confirmButton = {
                if (state.plan.actionable) {
                    TextButton(onClick = onConfirm) { Text(stringResource(R.string.relaunch_go)) }
                } else {
                    TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) }
                }
            },
            dismissButton = {
                if (state.plan.actionable) {
                    TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
                }
            },
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
                        // Sin esto, una operación entera omitida enseña «Relanzadas 0 de N» y nada
                        // más: el mismo silencio que en el equipo dijo «se han quedado como
                        // estaban» sobre una ventana que había muerto.
                        val skipped = RelaunchReasons.untouched(state.operation)
                        if (skipped.isNotEmpty()) {
                            Text(
                                stringResource(R.string.relaunch_skipped_some, skipped.size),
                                style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted,
                            )
                        }
                        val motivos = RelaunchReasons.distinctReasons(skipped + state.operation.retryable)
                        for (reason in motivos.map { textOf(it) }) {
                            Text(
                                reason,
                                style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
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

/**
 * La frase de una causa.
 *
 * Una causa que esta versión no conoce se muestra con su identificador literal en vez de
 * desaparecer: perder el diagnóstico es peor que no entenderlo.
 */
@Composable
private fun textOf(reason: RelaunchReason): String = when (reason.cause) {
    RelaunchCause.UNSUPPORTED -> stringResource(R.string.relaunch_cause_unsupported)
    RelaunchCause.AMBIGUOUS_IDENTITY -> stringResource(R.string.relaunch_cause_ambiguous)
    RelaunchCause.NO_AUTHORITY -> stringResource(R.string.relaunch_cause_no_authority)
    RelaunchCause.HOST_UNREACHABLE -> stringResource(R.string.relaunch_cause_unreachable)
    // Incluye `null`: una causa que esta versión no interpreta llega aquí con su identificador
    // intacto, y se enseña tal cual en vez de desaparecer.
    else -> stringResource(R.string.relaunch_cause_unknown, reason.wire)
}
