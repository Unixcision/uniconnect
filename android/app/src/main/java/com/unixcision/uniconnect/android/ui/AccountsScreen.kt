package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AccountChip
import com.unixcision.uniconnect.android.domain.AccountChipCount
import com.unixcision.uniconnect.android.domain.AccountGroup
import com.unixcision.uniconnect.android.domain.AccountHost
import com.unixcision.uniconnect.android.domain.AccountLabel
import com.unixcision.uniconnect.android.domain.AccountMethod
import com.unixcision.uniconnect.android.domain.AccountNotice
import com.unixcision.uniconnect.android.domain.AccountPalette
import com.unixcision.uniconnect.android.domain.AccountRow
import com.unixcision.uniconnect.android.domain.AccountStatus
import com.unixcision.uniconnect.android.domain.AccountUsageMath
import com.unixcision.uniconnect.android.domain.CodexResetMessage
import com.unixcision.uniconnect.android.domain.CodexResetStep
import com.unixcision.uniconnect.android.domain.CodexResetTarget
import com.unixcision.uniconnect.android.domain.AccountsFailure
import com.unixcision.uniconnect.android.domain.AccountsQuery
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * «Cuentas de IA» a pantalla completa (`accounts.v1`): con qué cuenta está cada IA de cada equipo,
 * por espacio o por cuenta, con fichas de cuenta y buscador.
 *
 * Lee al abrir, al tirar para refrescar, con «Actualizar» y cada 15 s mientras está a la vista; al
 * salir, o al ir la app a segundo plano, deja de leer y olvida la lectura. Un equipo que no contesta
 * sale arriba con su aviso y sin filas: nunca con lo que dijo la vez anterior.
 *
 * @param machines los equipos que anuncian `accounts.v1`.
 * @param onOpenWindow abre la ventana de una fila en su equipo.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountsScreen(
    model: AccountsViewModel,
    machines: List<Machine>,
    onBack: () -> Unit,
    onOpenWindow: (machineID: String, workspaceID: String, windowID: String) -> Unit,
    /** Los equipos que anuncian `accounts.codex_reset.v1`: solo en ellos se ofrece gastar un reseteo. */
    codexResetMachines: Set<String> = emptySet(),
) {
    val state by model.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var pulling by remember { mutableStateOf(false) }
    LaunchedEffect(lifecycle, machines) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                // «Hace N s» avanza solo mientras se ve.
                launch {
                    while (true) {
                        now = System.currentTimeMillis()
                        delay(TICK_MILLIS)
                    }
                }
                // El ritmo que fija el contrato: al abrir y luego cada 15 s, solo a la vista.
                while (true) {
                    model.refresh(machines)
                    delay(REFRESH_MILLIS)
                }
            } finally {
                model.stop()
            }
        }
    }
    val refresh: () -> Unit = { scope.launch { model.refresh(machines) } }
    val board = state.board
    val query = state.query
    val chips = remember(board, query) { board?.chips(query).orEmpty() }
    val groups = remember(board, query) { board?.groups(query).orEmpty() }
    val spacing = UniTheme.spacing
    // La hora de la pantalla para todo lo que depende de ella: ningún cálculo mira el reloj.
    val zone = remember { ZoneId.systemDefault() }
    val instant = Instant.ofEpochMilli(now)
    val math = remember(now, zone) { AccountUsageMath(instant, zone) }

    Column(Modifier.fillMaxSize()) {
        Header(reading = state.reading, ageSeconds = board?.ageSeconds(now), onBack = onBack, onRefresh = refresh)
        TabSelector(state.tab, model::showTab, Modifier.padding(horizontal = spacing.page).padding(bottom = 6.dp))
        PullToRefreshBox(
            isRefreshing = pulling,
            onRefresh = {
                pulling = true
                scope.launch {
                    try { model.refresh(machines) } finally { pulling = false }
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = spacing.page, end = spacing.page, top = 4.dp, bottom = 40.dp),
                verticalArrangement = Arrangement.spacedBy(spacing.gap),
            ) {
                when {
                    machines.isEmpty() -> item { Empty(stringResource(R.string.accounts_empty_machines)) }
                    // Hasta que llega la primera lectura no se pinta nada: no hay nada viejo que enseñar.
                    board == null -> item {
                        Row(Modifier.fillMaxWidth().padding(vertical = 32.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            Spinner(28)
                            Spacer(Modifier.width(12.dp))
                            Text(stringResource(R.string.accounts_reading), color = UniTheme.colors.muted)
                        }
                    }
                    state.tab == AccountsViewModel.Tab.USAGE -> {
                        // Lo que no se pudo leer también falta aquí: se dice antes que nada.
                        items(board.notices) { NoticeCard(it) }
                        usageItems(
                            board, state.usageKey, math, instant, zone,
                            onSelect = model::showUsage, onOpenWindow = onOpenWindow, onShowWindows = model::showWindowsOf,
                            resetTarget = { CodexResetTarget.of(it, codexResetMachines) }, reset = state.reset, onAskReset = model::askReset,
                        )
                    }
                    else -> {
                        item { Chips(chips, query.chip, model::choose) }
                        item { SearchField(query.search, model::search) }
                        item { GroupingControls(query, model::group, model::showWithoutAgent) }
                        items(board.notices) { NoticeCard(it) }
                        if (groups.isEmpty()) {
                            item { Empty(stringResource(if (board.rows.isEmpty()) R.string.accounts_empty else R.string.accounts_empty_filter)) }
                        }
                        items(groups) { group -> GroupCard(group, query.grouping, onOpenWindow) }
                    }
                }
            }
        }
    }
    ResetDialogs(state.reset, onConfirm = model::confirmReset, onCancel = model::cancelReset, onRetry = model::retryReset, onDismiss = model::dismissReset)
}

/** Título, «Leído en vivo hace N s» y «Actualizar», con un indicador mientras lee. */
@Composable
private fun Header(reading: Boolean, ageSeconds: Long?, onBack: () -> Unit, onRefresh: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 12.dp, top = 10.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
        Column(Modifier.weight(1f).padding(start = 8.dp)) {
            Text(stringResource(R.string.accounts_title), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Text(
                when {
                    ageSeconds == null -> stringResource(R.string.accounts_reading)
                    ageSeconds < 60 -> stringResource(R.string.accounts_read_seconds, ageSeconds.toInt())
                    else -> stringResource(R.string.accounts_read_minutes, (ageSeconds / 60).toInt())
                },
                style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted, maxLines = 1,
            )
        }
        TextButton(onClick = onRefresh, enabled = !reading) {
            if (reading) Spinner(18) else Icon(Icons.Rounded.Refresh, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.accounts_refresh))
        }
    }
}

/** «Ventanas | Uso por cuenta» (§4.1). */
@Composable
private fun TabSelector(tab: AccountsViewModel.Tab, onTab: (AccountsViewModel.Tab) -> Unit, modifier: Modifier) {
    val options = listOf(AccountsViewModel.Tab.WINDOWS to R.string.accounts_tab_windows, AccountsViewModel.Tab.USAGE to R.string.accounts_tab_usage)
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (option, label) ->
            SegmentedButton(
                selected = tab == option, onClick = { onTab(option) },
                shape = SegmentedButtonDefaults.itemShape(index, options.size), colors = segmentColors(),
            ) { Text(stringResource(label), maxLines = 1) }
        }
    }
}

@Composable
private fun segmentColors() = SegmentedButtonDefaults.colors(
    activeContainerColor = UniTheme.colors.accent.copy(alpha = .18f), activeContentColor = UniTheme.colors.accent,
    activeBorderColor = UniTheme.colors.accent.copy(alpha = .5f), inactiveContentColor = UniTheme.colors.muted,
    inactiveBorderColor = UniTheme.colors.outline,
)

/** «Todas», una ficha por cuenta con su color, «Sin sesión» y «Sin leer». Pulsar la elegida la quita. */
@Composable
private fun Chips(chips: List<AccountChipCount>, selected: AccountChip, onChoose: (AccountChip) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        chips.forEach { item ->
            val chosen = item.chip == selected
            val tone = item.colorIndex?.let { Color(AccountPalette.COLORS[it]) }
            FilterChip(
                selected = chosen,
                onClick = { onChoose(if (chosen) AccountChip.All else item.chip) },
                label = {
                    Text(
                        when (val chip = item.chip) {
                            AccountChip.All -> stringResource(R.string.accounts_chip_all, item.count)
                            is AccountChip.Email -> stringResource(R.string.accounts_chip_email, chip.email, item.count)
                            AccountChip.NoSession -> stringResource(R.string.accounts_chip_no_session, item.count)
                            AccountChip.Unread -> stringResource(R.string.accounts_chip_unread, item.count)
                        },
                        maxLines = 1,
                    )
                },
                leadingIcon = if (tone != null) { { Dot(tone) } } else null,
            )
        }
    }
}

@Composable
private fun SearchField(text: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = text, onValueChange = onChange, modifier = Modifier.fillMaxWidth(), singleLine = true,
        placeholder = { Text(stringResource(R.string.accounts_search), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingIcon = { Icon(Icons.Rounded.Search, null, tint = UniTheme.colors.muted) },
        trailingIcon = if (text.isNotEmpty()) {
            { IconButton(onClick = { onChange("") }) { Icon(Icons.Rounded.Close, stringResource(R.string.accounts_search_clear)) } }
        } else null,
        shape = UniTheme.shapes.card,
    )
}

/** «Por espacio» o «Por cuenta», y el interruptor «Ventanas sin IA». */
@Composable
private fun GroupingControls(query: AccountsQuery, onGroup: (AccountsQuery.Grouping) -> Unit, onShowWithoutAgent: (Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val options = listOf(
            AccountsQuery.Grouping.BY_WORKSPACE to R.string.accounts_by_workspace,
            AccountsQuery.Grouping.BY_ACCOUNT to R.string.accounts_by_account,
        )
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, (grouping, label) ->
                SegmentedButton(
                    selected = query.grouping == grouping,
                    onClick = { onGroup(grouping) },
                    shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    colors = segmentColors(),
                ) { Text(stringResource(label), maxLines = 1) }
            }
        }
        Row(
            Modifier.fillMaxWidth().clickable { onShowWithoutAgent(!query.showWithoutAgent) }.padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.accounts_without_agent), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Switch(
                checked = query.showWithoutAgent, onCheckedChange = onShowWithoutAgent,
                colors = SwitchDefaults.colors(checkedTrackColor = UniTheme.colors.accent, checkedThumbColor = UniTheme.colors.onAccent),
            )
        }
    }
}

/** Lo que no se pudo leer y por eso no sale: un equipo entero o un host suyo. */
@Composable
private fun NoticeCard(notice: AccountNotice) {
    val text = when (notice) {
        is AccountNotice.MachineFailed -> when (notice.failure.kind) {
            AccountsFailure.Kind.UNREACHABLE -> stringResource(R.string.accounts_machine_unreachable, notice.machineName)
            AccountsFailure.Kind.LOCKED -> stringResource(R.string.accounts_machine_locked, notice.machineName)
            AccountsFailure.Kind.UNSUPPORTED -> stringResource(R.string.accounts_machine_unsupported, notice.machineName)
            AccountsFailure.Kind.MALFORMED -> stringResource(R.string.accounts_machine_malformed, notice.machineName)
            AccountsFailure.Kind.REJECTED -> stringResource(
                R.string.accounts_machine_rejected, notice.machineName,
                listOfNotNull(notice.failure.code, notice.failure.detail).joinToString(" · ").ifEmpty { "?" },
            )
        }
        // La causa que da el equipo manda; sin ella, la del estado.
        is AccountNotice.HostUnreadable -> notice.error?.let { error -> stringResource(R.string.accounts_host_other, notice.hostLabel, hostErrorText(error)) }
            ?: when (notice.state) {
                AccountHost.UNREACHABLE -> stringResource(R.string.accounts_host_unreachable, notice.hostLabel)
                AccountHost.VAULT_LOCKED -> stringResource(R.string.accounts_host_vault, notice.hostLabel)
                else -> stringResource(R.string.accounts_host_other, notice.hostLabel, notice.state)
            }
    }
    Surface(Modifier.fillMaxWidth(), color = UniTheme.colors.warning.copy(alpha = .12f), shape = UniTheme.shapes.card) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.CloudOff, null, Modifier.size(18.dp), tint = UniTheme.colors.warning)
            Spacer(Modifier.width(10.dp))
            Text(text, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.text)
        }
    }
}

/** La causa de un host que no se pudo leer (`hosts[].error`); una que no se conoce, tal cual. */
@Composable
private fun hostErrorText(error: String): String = when (error) {
    "sin_respuesta" -> stringResource(R.string.host_error_no_answer)
    "sin_python3" -> stringResource(R.string.host_error_no_python)
    "ssh_fallo" -> stringResource(R.string.host_error_ssh)
    "salida_no_valida" -> stringResource(R.string.host_error_bad_output)
    "tmux_no_disponible" -> stringResource(R.string.host_error_no_tmux)
    "tmux_fallo" -> stringResource(R.string.host_error_tmux)
    else -> error
}

/**
 * La confirmación de gastar un reseteo gratis de Codex (§5) y lo que pasó después. Un fallo ofrece
 * «Reintentar», que repite con la misma clave y nunca gasta dos.
 */
@Composable
private fun ResetDialogs(step: CodexResetStep, onConfirm: () -> Unit, onCancel: () -> Unit, onRetry: () -> Unit, onDismiss: () -> Unit) {
    when (step) {
        is CodexResetStep.Confirming -> AlertDialog(
            onDismissRequest = onCancel,
            title = { Text(pluralStringResource(R.plurals.reset_confirm_title, step.target.available, step.target.available, step.target.email)) },
            text = { Text(stringResource(R.string.reset_confirm_body), style = MaterialTheme.typography.bodyMedium) },
            confirmButton = { TextButton(onClick = onConfirm) { Text(stringResource(R.string.reset_go), color = UniTheme.colors.danger) } },
            dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) } },
            containerColor = UniTheme.colors.surface,
        )
        is CodexResetStep.Done, is CodexResetStep.Failed -> {
            val message = CodexResetMessage.of(step) ?: return
            val retries = step is CodexResetStep.Failed && message != CodexResetMessage.UNSUPPORTED && message != CodexResetMessage.INVALID
            AlertDialog(
                onDismissRequest = onDismiss,
                title = { Text(stringResource(if (step is CodexResetStep.Done) R.string.reset_title else R.string.reset_failed_title)) },
                text = { Text(resetMessageText(message, step), style = MaterialTheme.typography.bodyMedium) },
                confirmButton = {
                    if (retries) TextButton(onClick = onRetry) { Text(stringResource(R.string.reset_retry)) }
                    else TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) }
                },
                dismissButton = { if (retries) TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
                containerColor = UniTheme.colors.surface,
            )
        }
        CodexResetStep.Idle, is CodexResetStep.Running -> Unit
    }
}

@Composable
private fun resetMessageText(message: CodexResetMessage, step: CodexResetStep): String = when (message) {
    CodexResetMessage.DONE -> stringResource(R.string.reset_done, (step as? CodexResetStep.Done)?.target?.email.orEmpty())
    CodexResetMessage.NOTHING_TO_RESET -> stringResource(R.string.reset_nothing)
    CodexResetMessage.NO_CREDIT -> stringResource(R.string.reset_no_credit)
    CodexResetMessage.ALREADY_REDEEMED -> stringResource(R.string.reset_already)
    CodexResetMessage.UNKNOWN_OUTCOME -> stringResource(R.string.reset_unknown, (step as? CodexResetStep.Done)?.result?.outcomeWire.orEmpty())
    CodexResetMessage.NOT_FOUND -> stringResource(R.string.reset_not_found)
    CodexResetMessage.UNAVAILABLE -> stringResource(R.string.reset_unavailable)
    CodexResetMessage.LOCKED -> stringResource(R.string.reset_locked)
    CodexResetMessage.INVALID -> stringResource(R.string.reset_invalid)
    CodexResetMessage.UNSUPPORTED -> stringResource(R.string.reset_unsupported)
    CodexResetMessage.UNREACHABLE -> stringResource(R.string.reset_unreachable)
    CodexResetMessage.OTHER -> stringResource(R.string.reset_other, (step as? CodexResetStep.Failed)?.failure?.code ?: "?")
}

/** Un grupo: su cabecera y sus ventanas en una tarjeta. */
@Composable
private fun GroupCard(group: AccountGroup, grouping: AccountsQuery.Grouping, onOpenWindow: (String, String, String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        GroupHeader(group)
        GlassCard(Modifier.fillMaxWidth()) {
            group.rows.forEachIndexed { index, row ->
                if (index > 0) HorizontalDivider(Modifier.padding(horizontal = 14.dp), color = UniTheme.colors.outline)
                WindowRow(row, showHost = grouping == AccountsQuery.Grouping.BY_ACCOUNT) {
                    onOpenWindow(row.machineID, row.window.workspaceID, row.window.terminalID)
                }
            }
        }
    }
}

@Composable
private fun GroupHeader(group: AccountGroup) {
    val windows = pluralStringResource(R.plurals.accounts_group_windows, group.rows.size, group.rows.size)
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        when (val key = group.key) {
            is AccountGroup.Key.Workspace -> Column(Modifier.weight(1f)) {
                Text(key.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    group.rows.map { it.hostLabel }.distinct().joinToString(", "),
                    style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            is AccountGroup.Key.Email -> Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                Dot(Color(AccountPalette.COLORS[key.colorIndex]), 12)
                Spacer(Modifier.width(8.dp))
                Text(key.email, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = Color(AccountPalette.COLORS[key.colorIndex]), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            else -> Text(groupTitle(key), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
        }
        Spacer(Modifier.width(8.dp))
        Text(
            if (group.key is AccountGroup.Key.Workspace) windows
            else "$windows · ${pluralStringResource(R.plurals.accounts_group_hosts, group.hostCount, group.hostCount)}",
            style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 1,
        )
    }
}

@Composable
private fun groupTitle(key: AccountGroup.Key): String = when (key) {
    is AccountGroup.Key.Method -> methodText(key.method)
    AccountGroup.Key.NoSession -> stringResource(R.string.accounts_group_no_session)
    AccountGroup.Key.Unread -> stringResource(R.string.accounts_group_unread)
    AccountGroup.Key.WithoutAgent -> stringResource(R.string.accounts_group_without_agent)
    AccountGroup.Key.NoEmail -> stringResource(R.string.accounts_group_no_email)
    is AccountGroup.Key.Email -> key.email
    is AccountGroup.Key.Workspace -> key.name
}

/**
 * Una ventana: su nombre y su IA, la cuenta en grande con su color (o el estado en gris), el plan,
 * y debajo el usuario del sistema y el fichero que se leyó.
 */
@Composable
private fun WindowRow(row: AccountRow, showHost: Boolean, onClick: () -> Unit) {
    val account = row.window.account
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(row.window.window, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
            row.window.agent?.let { Badge(it.displayName, UniTheme.colors.muted) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                when (val label = row.label) {
                    is AccountLabel.Email -> Text(
                        label.email, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                        color = Color(AccountPalette.COLORS[label.colorIndex]), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    is AccountLabel.Method -> Text(methodText(label.method), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
                    is AccountLabel.Status -> Text(statusText(label), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
                    is AccountLabel.Unknown -> Text(stringResource(R.string.accounts_status_unknown, label.wire), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
                }
            }
            account?.plan?.takeIf { row.label is AccountLabel.Email || row.label is AccountLabel.Method }?.let { Badge(it, UniTheme.colors.accent) }
        }
        val details = listOfNotNull(account?.osUser, account?.config).joinToString(" · ")
        if (details.isNotEmpty()) {
            Text(details, style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (showHost) {
            Text(row.hostLabel, style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun statusText(label: AccountLabel.Status): String = when (label.status) {
    AccountStatus.NO_SESSION -> stringResource(R.string.accounts_status_no_session)
    AccountStatus.NOT_READABLE -> label.osUser?.let { stringResource(R.string.accounts_status_not_readable_as, it) }
        ?: stringResource(R.string.accounts_status_not_readable)
    AccountStatus.NOT_EXPOSED -> stringResource(R.string.accounts_status_not_exposed)
    AccountStatus.HOST_UNREACHABLE -> stringResource(R.string.accounts_status_host_unreachable)
    AccountStatus.NO_AGENT -> stringResource(R.string.accounts_status_no_agent)
    AccountStatus.SESSION_NOT_ALIVE -> stringResource(R.string.accounts_status_session_not_alive)
    AccountStatus.NO_TMUX -> stringResource(R.string.accounts_status_no_tmux)
    AccountStatus.DEAD_PANE -> stringResource(R.string.accounts_status_dead_pane)
    AccountStatus.AMBIGUOUS_IDENTITY -> stringResource(R.string.accounts_status_ambiguous)
    AccountStatus.NO_EMAIL -> stringResource(R.string.accounts_status_no_email)
}

@Composable
private fun methodText(method: AccountMethod): String = when (method) {
    AccountMethod.API_KEY -> stringResource(R.string.accounts_method_api_key)
    AccountMethod.BEDROCK -> stringResource(R.string.accounts_method_bedrock)
    AccountMethod.VERTEX -> stringResource(R.string.accounts_method_vertex)
    AccountMethod.FOUNDRY -> stringResource(R.string.accounts_method_foundry)
}

/** Una insignia pequeña: la IA de la ventana o el plan de la cuenta. */
@Composable
private fun Badge(text: String, color: Color) {
    Text(
        text, Modifier.background(color.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
        style = MaterialTheme.typography.labelSmall, color = color, fontWeight = FontWeight.Bold, maxLines = 1,
    )
}

@Composable
private fun Dot(color: Color, size: Int = 10) {
    Box(Modifier.size(size.dp).background(color, CircleShape))
}

@Composable
private fun Empty(text: String) {
    Text(text, Modifier.fillMaxWidth().padding(vertical = 32.dp), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun Spinner(size: Int) {
    LoadingIndicator(Modifier.size(size.dp), color = UniTheme.colors.accent)
}

/** Cada cuánto se relee mientras la pantalla está a la vista (`accounts.v1`, §1). */
private const val REFRESH_MILLIS = 15_000L

/** Cada cuánto avanza «hace N s». */
private const val TICK_MILLIS = 1_000L
