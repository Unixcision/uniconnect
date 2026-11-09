package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.RelaunchCause
import com.unixcision.uniconnect.android.domain.RelaunchCost
import com.unixcision.uniconnect.android.domain.RelaunchHostPlan
import com.unixcision.uniconnect.android.domain.RelaunchHostProblem
import com.unixcision.uniconnect.android.domain.RelaunchOptions
import com.unixcision.uniconnect.android.domain.RelaunchReason
import com.unixcision.uniconnect.android.domain.RelaunchTarget
import com.unixcision.uniconnect.android.domain.RelaunchUpdate
import com.unixcision.uniconnect.android.domain.RelaunchVerb
import com.unixcision.uniconnect.android.domain.TokenAmount
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Enseña un relanzado o «Actualizar Claude» antes, durante y después, de uno o de varios equipos.
 *
 * Después se enseña siempre, también cuando todo fue bien: tras reiniciar veintiséis agentes,
 * «no ha saltado nada» no es lo mismo que saber que volvieron los veintiséis.
 *
 * @param onOptions otro modelo o effort para «Actualizar Claude»; el ViewModel vuelve a pedir el plan.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RelaunchDialog(state: RelaunchUI, onConfirm: () -> Unit, onOptions: (RelaunchOptions) -> Unit, onDismiss: () -> Unit) {
    val update = state.request.verb == RelaunchVerb.UPDATE
    when (state) {
        is RelaunchUI.Planning -> AlertDialog(
            // Pedir un plan no toca nada: se puede cancelar.
            onDismissRequest = onDismiss,
            title = { Text(stringResource(if (update) R.string.update_planning else R.string.relaunch_planning)) },
            text = { LoadingIndicator(Modifier.size(28.dp), color = UniTheme.colors.accent) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
            containerColor = UniTheme.colors.surface,
        )

        is RelaunchUI.Confirm -> ConfirmDialog(state, onConfirm, onOptions, onDismiss)

        is RelaunchUI.Running -> AlertDialog(
            // Sin botón de cerrar a propósito: el equipo ya lo aceptó y cerrar esto no lo detendría.
            onDismissRequest = {},
            title = {
                Text(
                    if (update) pluralStringResource(R.plurals.update_running, state.total, state.total)
                    else stringResource(R.string.relaunch_running, state.total)
                )
            },
            text = { LoadingIndicator(Modifier.size(28.dp), color = UniTheme.colors.accent) },
            confirmButton = {},
            containerColor = UniTheme.colors.surface,
        )

        is RelaunchUI.Done -> DoneDialog(state, onDismiss)

        is RelaunchUI.Failed -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text(stringResource(if (update) R.string.update_claude else R.string.relaunch_agents)) },
            text = { Text(stringResource(state.message), style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
            containerColor = UniTheme.colors.surface,
        )
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ConfirmDialog(state: RelaunchUI.Confirm, onConfirm: () -> Unit, onOptions: (RelaunchOptions) -> Unit, onDismiss: () -> Unit) {
    val preview = state.preview
    val update = state.request.verb == RelaunchVerb.UPDATE
    val actionable = preview.actionable
    // Con un solo equipo no se nombra: ya se sabe cuál es. En «todo», cada uno con su nombre.
    val named = preview.hosts.size > 1 || state.request.everywhere
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                when {
                    !actionable -> stringResource(if (update) R.string.update_unavailable_title else R.string.relaunch_unavailable_title)
                    update -> pluralStringResource(R.plurals.update_confirm_title, preview.targetCount, preview.targetCount)
                    else -> stringResource(R.string.relaunch_confirm_title, preview.targetCount)
                }
            )
        },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // Cambiar el modelo o el effort no cambia qué ventanas entran; solo tiene sentido
                // si hay algo que ejecutar, o si el equipo rechazó las opciones pedidas.
                if (update && (actionable || state.replanning || preview.failed.any { it.errorCode == BAD_OPTIONS })) {
                    OptionPickers(state.request.options, enabled = !state.replanning, onOptions)
                }
                if (state.replanning) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.accent)
                        Text(stringResource(R.string.update_replanning), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
                    }
                }
                if (actionable) {
                    Text(
                        stringResource(if (update) R.string.update_confirm_note else R.string.relaunch_confirm_note),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    // Lo que gasta es escribirles, no reabrirlas: se dice antes de pulsar.
                    costText(preview.cost)?.let { (text, spends) ->
                        Text(
                            text, style = MaterialTheme.typography.bodyMedium,
                            color = if (spends) UniTheme.colors.warning else UniTheme.colors.muted,
                        )
                    }
                }
                preview.hosts.forEach { host -> HostPlan(host, named, update) }
            }
        },
        // Sin nada que hacer no se ofrece «Adelante»: un botón que no va a hacer nada es peor que
        // no tenerlo, porque quien lo pulsa se queda esperando.
        confirmButton = {
            if (actionable) {
                TextButton(onClick = onConfirm, enabled = !state.replanning) {
                    Text(stringResource(if (update) R.string.update_go else R.string.relaunch_go))
                }
            } else {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) }
            }
        },
        dismissButton = {
            if (actionable) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
            }
        },
        containerColor = UniTheme.colors.surface,
    )
}

/** Lo que el plan de un equipo dice: su motivo global, sus ventanas con sus avisos y lo que deja fuera. */
@Composable
private fun HostPlan(host: RelaunchHostPlan, named: Boolean, update: Boolean) {
    val plan = host.plan
    if (plan == null) {
        Text(problemText(host.machineName, host.problem, host.errorCode), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
        return
    }
    if (named) {
        Text(host.machineName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = UniTheme.type.identifierFamily)
    }
    // Si el equipo ya ha dicho que no puede, se dice aquí y no después de pulsar.
    plan.unavailableReason?.let { reason ->
        Text(reason, style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.warning)
    }
    // Se nombran unas cuantas: una cifra sola no deja comprobar que son las que uno creía, y aquí
    // el coste de equivocarse es reiniciar el agente de otro.
    plan.targets.take(TARGETS_SHOWN).forEach { TargetLines(it, update) }
    if (plan.targets.size > TARGETS_SHOWN) {
        Text("· …", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
    }
    if (plan.exclusions.isNotEmpty()) {
        Text(
            stringResource(R.string.relaunch_confirm_excluded, plan.exclusions.size),
            style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning,
        )
        // Con motivo global basta la frase de arriba; sin él —el equipo excluyó sus candidatos uno a
        // uno— las causas están aquí y en ningún otro sitio. Con objetivos, el total basta: las
        // ventanas nombradas arriba son las que importan. Sin objetivos, las excluidas son lo único
        // que hay, y un total con un motivo suelto no deja saber a QUÉ ventana le pasa qué.
        if (plan.targets.isEmpty()) {
            plan.exclusions.take(TARGETS_SHOWN).forEach { exclusion ->
                val motivo = exclusion.reason?.let { " — ${textOf(it)}" }.orEmpty()
                Text("· ${exclusion.label}$motivo", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
            }
            if (plan.exclusions.size > TARGETS_SHOWN) {
                Text("· …", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
            }
        } else if (plan.unavailableReason == null) {
            for (motivo in plan.exclusions.mapNotNull { it.reason }.distinctBy { it.wire }) {
                Text(textOf(motivo), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
            }
        }
    }
}

/** Una ventana del plan y lo que se le va a hacer, dicho antes de confirmar. */
@Composable
private fun TargetLines(target: RelaunchTarget, update: Boolean) {
    val indent = Modifier.padding(start = 10.dp)
    Text("· ${target.label}", style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
    val monitors = target.background?.takeIf { it > 0 }
    // Con el recuento de monitores, «tareas de fondo» sería decir lo mismo dos veces.
    target.warning?.takeIf { monitors == null || it.cause != RelaunchCause.BACKGROUND_TASKS }?.let { warning ->
        Text(textOf(warning), indent, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
    }
    monitors?.let { count ->
        Text(pluralStringResource(R.plurals.relaunch_target_monitors, count, count), indent, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning)
    }
    if (target.draft == true) {
        Text(stringResource(R.string.relaunch_target_draft), indent, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
    }
    if (update) target.version?.let { version ->
        val installed = target.installed?.takeIf { it != version }
        Text(
            if (installed != null) stringResource(R.string.relaunch_target_version, version, installed)
            else stringResource(R.string.relaunch_target_version_only, version),
            indent, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
        )
    }
}

/** Modelo y effort con los que reabrir; «Igual» no viaja y el equipo conserva el de la conversación. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun OptionPickers(options: RelaunchOptions, enabled: Boolean, onOptions: (RelaunchOptions) -> Unit) {
    Text(stringResource(R.string.update_model_label), style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        (listOf<String?>(null) + RelaunchOptions.MODELS).forEach { model ->
            FilterChip(
                selected = options.model == model, enabled = enabled,
                onClick = { onOptions(options.copy(model = model)) },
                label = { Text(modelLabel(model)) },
            )
        }
    }
    Text(stringResource(R.string.update_effort_label), style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        (listOf<String?>(null) + RelaunchOptions.EFFORTS).forEach { effort ->
            FilterChip(
                selected = options.effort == effort, enabled = enabled,
                onClick = { onOptions(options.copy(effort = effort)) },
                // Los efforts se enseñan como los escribe Claude (`/effort high`).
                label = { Text(effort ?: stringResource(R.string.update_same_short)) },
            )
        }
    }
}

@Composable
private fun modelLabel(model: String?): String = when (model) {
    null -> stringResource(R.string.update_same)
    "fable[1m]" -> stringResource(R.string.update_model_fable)
    "opus[1m]" -> stringResource(R.string.update_model_opus)
    "sonnet[1m]" -> stringResource(R.string.update_model_sonnet)
    "haiku" -> stringResource(R.string.update_model_haiku)
    else -> model
}

@Composable
private fun DoneDialog(state: RelaunchUI.Done, onDismiss: () -> Unit) {
    val outcome = state.outcome
    val update = state.request.verb == RelaunchVerb.UPDATE
    val body = MaterialTheme.typography.bodyMedium
    val small = MaterialTheme.typography.bodySmall
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                // «0 de 0» no dice nada cuando lo que pasó es que un equipo no contestó.
                if (outcome.total == 0 && outcome.problems.isNotEmpty()) {
                    stringResource(if (update) R.string.update_claude else R.string.relaunch_agents)
                } else {
                    stringResource(if (update) R.string.update_done_title else R.string.relaunch_done_title, outcome.verified, outcome.total)
                }
            )
        },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // Primero la versión: es lo que se pidió, y si falló, sus ventanas siguen como estaban.
                for (item in outcome.updates) {
                    Text(
                        updateLine(item), style = small,
                        color = if (item.kind == RelaunchUpdate.Kind.FAILED) UniTheme.colors.danger else UniTheme.colors.muted,
                    )
                }
                if (outcome.needingUser.isNotEmpty()) {
                    Text(stringResource(R.string.relaunch_needs_user, outcome.needingUser.size), style = body, color = UniTheme.colors.warning)
                }
                if (outcome.retryable.isNotEmpty()) {
                    Text(stringResource(R.string.relaunch_failed_some, outcome.retryable.size), style = body, color = UniTheme.colors.danger)
                }
                // Sin esto, una operación entera omitida enseña «Relanzadas 0 de N» y nada más: el
                // mismo silencio que en el equipo dijo «se han quedado como estaban» sobre una
                // ventana que había muerto.
                if (outcome.untouched.isNotEmpty()) {
                    Text(stringResource(R.string.relaunch_skipped_some, outcome.untouched.size), style = body, color = UniTheme.colors.muted)
                }
                // También los de quien espera a una persona: «2 esperan a que contestes» sin decir a
                // qué (¿la carpeta?, ¿los permisos?) obliga a ir ventana por ventana.
                for (reason in outcome.reasons.map { textOf(it) }) {
                    Text(reason, style = small, color = UniTheme.colors.muted)
                }
                if (outcome.monitorsSaved > 0) {
                    Text(pluralStringResource(R.plurals.relaunch_done_monitors, outcome.monitorsSaved, outcome.monitorsSaved), style = small, color = UniTheme.colors.muted)
                }
                if (outcome.messagesSent > 0) {
                    Text(pluralStringResource(R.plurals.relaunch_done_messages, outcome.messagesSent, outcome.messagesSent), style = small, color = UniTheme.colors.muted)
                }
                if (outcome.draftsRestored > 0) {
                    Text(pluralStringResource(R.plurals.relaunch_done_drafts, outcome.draftsRestored, outcome.draftsRestored), style = small, color = UniTheme.colors.muted)
                }
                if (outcome.droppedOptions.isNotEmpty()) {
                    Text(stringResource(R.string.relaunch_done_dropped, outcome.droppedOptions.joinToString(", ")), style = small, color = UniTheme.colors.warning)
                }
                if (update && outcome.reportedModels.isNotEmpty()) {
                    Text(stringResource(R.string.relaunch_done_models, outcome.reportedModels.joinToString(", ")), style = small, color = UniTheme.colors.muted)
                }
                // El equipo que no contestó se nombra: en «todo», callárselo es esconderlo.
                for (host in outcome.problems) {
                    Text(problemText(host.machineName, host.problem, host.errorCode), style = small, color = UniTheme.colors.warning)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
        containerColor = UniTheme.colors.surface,
    )
}

/** Cómo fue `claude update` en una instalación. Un estado que esta versión no conoce se enseña tal cual. */
@Composable
private fun updateLine(item: RelaunchUpdate): String {
    val host = item.host.ifEmpty { "?" }
    return when (item.kind) {
        RelaunchUpdate.Kind.UPDATED -> if (item.from != null && item.to != null) {
            stringResource(R.string.update_line_updated, host, item.from, item.to)
        } else stringResource(R.string.update_line_updated_bare, host)
        RelaunchUpdate.Kind.UP_TO_DATE -> (item.to ?: item.from)?.let { stringResource(R.string.update_line_current, host, it) }
            ?: stringResource(R.string.update_line_current_bare, host)
        RelaunchUpdate.Kind.FAILED -> stringResource(R.string.update_line_failed, host)
        RelaunchUpdate.Kind.UNKNOWN -> stringResource(R.string.update_line_other, host, item.state)
    }
}

/** La línea de coste y si gasta, o nulo si los equipos no lo dicen (no se inventa una cifra). */
@Composable
private fun costText(cost: RelaunchCost): Pair<String, Boolean>? = when (cost) {
    RelaunchCost.Unknown -> null
    RelaunchCost.Free -> stringResource(R.string.relaunch_cost_free) to false
    is RelaunchCost.Rereads -> {
        val tokens = cost.tokens
        val text = if (tokens == null) {
            pluralStringResource(R.plurals.relaunch_cost_rereads_unknown, cost.messaged, cost.messaged)
        } else {
            pluralStringResource(
                if (cost.partial) R.plurals.relaunch_cost_rereads_min else R.plurals.relaunch_cost_rereads,
                cost.messaged, cost.messaged, tokensText(tokens),
            )
        }
        text to true
    }
}

@Composable
private fun tokensText(tokens: Long): String {
    val amount = TokenAmount.of(tokens)
    return stringResource(
        when (amount.scale) {
            TokenAmount.Scale.UNITS -> R.string.relaunch_tokens_units
            TokenAmount.Scale.THOUSANDS -> R.string.relaunch_tokens_thousands
            TokenAmount.Scale.MILLIONS -> R.string.relaunch_tokens_millions
        },
        amount.number,
    )
}

/** Por qué no hay plan o resultado de un equipo, con el error del contrato si el equipo lo dio. */
@Composable
private fun problemText(machineName: String, problem: RelaunchHostProblem?, errorCode: String?): String {
    val error = errorCode?.let { errorText(it) }
    return when {
        error != null -> stringResource(R.string.relaunch_host_rejected, machineName, error)
        problem == RelaunchHostProblem.RESULT_UNKNOWN -> stringResource(R.string.relaunch_host_result_unknown, machineName)
        else -> stringResource(R.string.relaunch_host_plan_failed, machineName)
    }
}

/** La frase de un error de la llamada (`errors.json`); uno que esta versión no conoce va con su código. */
@Composable
private fun errorText(code: String): String = when (code) {
    "token_caducado" -> stringResource(R.string.relaunch_error_token_expired)
    "token_no_valido" -> stringResource(R.string.relaunch_error_token_invalid)
    "operacion_desconocida" -> stringResource(R.string.relaunch_error_unknown_operation)
    "alcance_no_valido" -> stringResource(R.string.relaunch_error_bad_scope)
    BAD_OPTIONS -> stringResource(R.string.relaunch_error_bad_options)
    else -> stringResource(R.string.relaunch_error_other, code)
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
    RelaunchCause.FOLDER_TRUST -> stringResource(R.string.relaunch_cause_folder_trust)
    RelaunchCause.PERMISSIONS -> stringResource(R.string.relaunch_cause_permissions)
    RelaunchCause.UNKNOWN_DIALOG -> stringResource(R.string.relaunch_cause_unknown_dialog)
    RelaunchCause.NOT_SENT -> stringResource(R.string.relaunch_cause_not_sent)
    RelaunchCause.GENERATION_CHANGED -> stringResource(R.string.relaunch_cause_generation_changed)
    RelaunchCause.DUPLICATE -> stringResource(R.string.relaunch_cause_duplicate)
    RelaunchCause.NO_AGENT -> stringResource(R.string.relaunch_cause_no_agent)
    RelaunchCause.BACKGROUND_TASKS -> stringResource(R.string.relaunch_cause_background_tasks)
    RelaunchCause.PROVIDER_UNSUPPORTED -> stringResource(R.string.relaunch_cause_provider_unsupported)
    RelaunchCause.NO_TMUX -> stringResource(R.string.relaunch_cause_no_tmux)
    RelaunchCause.NO_CREDENTIAL -> stringResource(R.string.relaunch_cause_no_credential)
    RelaunchCause.TARGET_NOT_LINUX -> stringResource(R.string.relaunch_cause_target_not_linux)
    RelaunchCause.MISSING_FOLDER -> stringResource(R.string.relaunch_cause_missing_folder)
    RelaunchCause.MISSING_BINARY -> stringResource(R.string.relaunch_cause_missing_binary)
    RelaunchCause.NO_PAUSE -> stringResource(R.string.relaunch_cause_no_pause)
    RelaunchCause.SHARED_SESSION -> stringResource(R.string.relaunch_cause_shared_session)
    RelaunchCause.NO_LOGIN -> stringResource(R.string.relaunch_cause_no_login)
    RelaunchCause.SHARED_CONVERSATION -> stringResource(R.string.relaunch_cause_shared_conversation)
    RelaunchCause.UPDATE_FAILED -> stringResource(R.string.relaunch_cause_update_failed)
    // Una causa que esta versión no interpreta llega aquí con su identificador intacto, y se
    // enseña tal cual en vez de desaparecer.
    null -> stringResource(R.string.relaunch_cause_unknown, reason.wire)
}

/** Cuántas ventanas (o exclusiones) se nombran por equipo antes de resumir con «…». */
private const val TARGETS_SHOWN = 6

/** El error del contrato para unas opciones que el equipo no acepta. */
private const val BAD_OPTIONS = "opciones_no_validas"
