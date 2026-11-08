package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.ActivityDigest
import com.unixcision.uniconnect.android.domain.Greeting
import com.unixcision.uniconnect.android.ui.design.DesignedDrawer
import com.unixcision.uniconnect.android.ui.design.DesignedHome
import com.unixcision.uniconnect.android.ui.design.DrawerModel
import com.unixcision.uniconnect.android.ui.design.HomeActions
import com.unixcision.uniconnect.android.ui.design.HomeMachine
import com.unixcision.uniconnect.android.ui.design.HomeModel
import java.util.Calendar
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.unixcision.uniconnect.android.domain.HomeSummary
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.RelaunchScope
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.TranscriptionCandidate
import com.unixcision.uniconnect.android.domain.InboxCandidate
import com.unixcision.uniconnect.android.ui.components.BoxMonogram
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.PillTone
import com.unixcision.uniconnect.android.ui.components.StatusPill
import com.unixcision.uniconnect.android.ui.components.themedTone

private enum class Level { LOADING, LIST, UPLOADS, MACHINE, TERMINAL }

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MachinesScreen(model: MachinesViewModel, uploads: UploadViewModel, attachments: AttachViewModel, inbox: InboxViewModel, dictation: DictationViewModel, onEnableNotifications: (String) -> Unit, dictationHistory: DictationHistoryViewModel? = null) {
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { model.pauseLiveConnection() }
    LifecycleEventEffect(Lifecycle.Event.ON_START) { model.resumeLiveConnection() }
    val state by model.state.collectAsStateWithLifecycle()
    val machine = state.machines.firstOrNull { it.id == state.selectedMachine }
    val connection = machine?.let { state.connections[it.id] }
    val workspace = connection?.snapshot?.workspaces?.firstOrNull { it.id == state.selectedWorkspace }
    val window = workspace?.windows?.firstOrNull { it.id == state.selectedWindow }
    // Any saved machine may be the one that transcribes, not only the one of the open window: a
    // laptop with a big model answers far better than a small server with a small one. Opening a
    // machine stops watching the others, and that must not take the Mac out for a Linux window.
    val transcribers = remember(state.machines, state.connections) {
        state.machines.map { saved ->
            val link = state.connections[saved.id]
            TranscriptionCandidate.of(saved, link?.snapshot, watched = link?.connected == true, lastContactFailed = link?.error != null)
        }
    }
    // Against a host that keeps favourites itself, the phone's own copy is not shown.
    val overrides = machine?.takeIf { connection?.snapshot?.keepsBoxes != true }?.let { state.overrides[it.id] } ?: BoxOverrides()
    var removing by remember { mutableStateOf<Machine?>(null) }
    // "Enviar archivos" is a section of the home, not of a machine: opening a machine leaves it.
    var sendingFiles by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(machine?.id) { if (machine != null) sendingFiles = false }
    BackHandler(enabled = machine != null || sendingFiles) { if (machine != null) model.back() else sendingFiles = false }
    val level = when {
        state.loading -> Level.LOADING
        window != null -> Level.TERMINAL
        machine != null -> Level.MACHINE
        sendingFiles -> Level.UPLOADS
        else -> Level.LIST
    }

    // The side menu and what it opens: pages of Ajustes, the history and the notices.
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    var settingsPage by rememberSaveable { mutableStateOf<SettingsPage?>(null) }
    var historyOpen by rememberSaveable { mutableStateOf(false) }
    var noticesOpen by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val version = remember(context) {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()
    }
    val summaries = remember(state.machines, state.connections) {
        state.machines.associate { saved ->
            val link = state.connections[saved.id]
            saved.id to HomeSummary.of(link?.connected == true, link?.snapshot)
        }
    }
    val troubled = state.connectionTroubled || state.crashes.isNotEmpty()
    BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
    // While the home is on screen it looks again every few seconds, quietly: one look taken in
    // the middle of a burst (a host that redrew every window at once) must not stay frozen there.
    LaunchedEffect(level) {
        if (level == Level.LIST) while (true) {
            delay(HOME_REFRESH_MILLIS)
            model.refreshMachineStates(quiet = true)
        }
    }

    ModalNavigationDrawer(
        drawerState = drawer,
        gesturesEnabled = level == Level.LIST,
        scrimColor = Color.Black.copy(alpha = .32f),
        drawerContent = {
            DesignedDrawer(DrawerModel(HomeSummary.total(summaries.values.toList()), version, troubled, state.settings.designTheme)) { destination ->
                scope.launch { drawer.close() }
                when (destination) {
                    HomeDestination.Machines -> {}
                    HomeDestination.Files -> sendingFiles = true
                    HomeDestination.History -> historyOpen = true
                    HomeDestination.Notices -> noticesOpen = true
                    is HomeDestination.Settings -> settingsPage = destination.page
                    HomeDestination.Diagnostics -> model.showDiagnostics(true)
                }
            }
        },
    ) {
    // A flat ground in every theme: no gradient, no glow.
    Box(Modifier.fillMaxSize().background(UniTheme.colors.background)) {
        // System bars and cutout only: the IME is padded once, by the screen that hosts the composer.
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.systemBars.union(WindowInsets.displayCutout)).widthIn(max = 840.dp).align(Alignment.TopCenter)) {
            // The home and the machine screen are drawn by the design in force, header included.
            if (level == Level.UPLOADS || level == Level.TERMINAL) AppHeader(
                compact = level == Level.TERMINAL,
                title = window?.name ?: machine?.name ?: stringResource(if (level == Level.UPLOADS) R.string.upload_title else R.string.app_name),
                subtitle = when {
                    window != null -> "${machine?.name.orEmpty()} · ${workspace?.name.orEmpty()}"
                    machine != null -> machine.endpoint.displayAddress
                    level == Level.UPLOADS -> stringResource(R.string.upload_subtitle)
                    else -> stringResource(R.string.home_eyebrow)
                },
                showBack = machine != null || level == Level.UPLOADS,
                onBack = { if (machine != null) model.back() else sendingFiles = false },
                monogramSeed = machine?.name,
                pill = when {
                    machine == null -> null
                    connection?.connected == true -> stringResource(R.string.connected_machine) to PillTone.Live
                    connection?.checking == true -> stringResource(R.string.checking_machine) to PillTone.Busy
                    else -> stringResource(R.string.saved_machine) to PillTone.Idle
                },
            ) {}
            state.error?.let { ErrorNotice(it, model::dismissError) }
            state.actionNotice?.let { ErrorNotice(it, model::dismissActionNotice) }
            AnimatedContent(
                targetState = level,
                transitionSpec = {
                    val forward = targetState.ordinal >= initialState.ordinal
                    (fadeIn() + slideInHorizontally { if (forward) it / 8 else -it / 8 }) togetherWith
                        (fadeOut() + slideOutHorizontally { if (forward) -it / 8 else it / 8 })
                },
                label = "level",
            ) { target ->
                when (target) {
                    Level.LOADING -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingIndicator(color = UniTheme.colors.accent) }
                    Level.UPLOADS -> UploadScreen(uploads)
                    Level.TERMINAL -> key(machine?.id, workspace?.id, window?.id) {
                        TerminalScreen(
                            snapshot = state.terminal, loading = state.terminalLoading, error = state.terminalError, errorDetail = state.terminalErrorDetail,
                            sending = state.inputSending, reconnecting = state.reconnecting, connected = connection?.connected == true,
                            onRefresh = model::refreshTerminal, onReconnect = model::reconnectWindow,
                            onScroll = model::scrollTerminal, onSend = model::sendInput,
                            real = state.realTerminal, attachUnsupported = machine?.id in state.attachUnsupported,
                            attachFallbackDetail = state.attachFallbackDetail,
                            onStartReal = model::startRealTerminal, onStopReal = model::stopRealTerminal,
                            onPty = model::sendPty, onPtyWheel = model::wheelPty, onPtyResize = model::resizePty,
                            onLeaveCopyMode = model::leaveCopyMode, settings = state.settings,
                            resumeReal = state.resumeRealTerminal, view = state.terminalView, zoom = state.terminalZoom,
                            onView = model::setTerminalView, onZoom = model::setTerminalZoom, onReconnectReal = model::reconnectRealTerminal,
                            draft = state.draft, onDraftChange = model::updateDraft,
                            windowPinned = window?.isPinned == true || window?.id in overrides.pinnedWindows,
                            onTogglePin = { window?.let { model.toggleWindowPinned(it.id) } },
                            activity = window?.activity?.state ?: ActivityState.UNKNOWN,
                            attachments = attachments,
                            inbox = inbox,
                            dictation = dictation,
                            dictationHistory = dictationHistory,
                            windowName = window?.name,
                            attachTarget = if (machine != null && workspace != null && window != null) AttachTarget(machine, workspace.id, window.id, workspace.isSSH, connection?.snapshot?.putsFiles == true, connection?.snapshot?.keepsInbox == true) else null,
                            transcribers = transcribers,
                            onDiagnostics = { model.showDiagnostics(true) },
                            // Solo si el equipo sabe darlos: uno antiguo contestaría method_not_found.
                            onDetails = if (connection?.snapshot?.describesWindows == true && machine != null && workspace != null && window != null) {
                                { model.showWindowDetails(machine.id, workspace.id, window.id) }
                            } else null,
                            // Mismo criterio que la pulsación larga: sin relaunch.v1 no se ofrece, y
                            // con los tokens de D7 solo si el equipo sabe relanzar esa IA en ese
                            // tipo de ventana (contracts/relaunch-v1/proveedores.json).
                            onRelaunchWindow = if (machine != null && workspace != null && window != null &&
                                connection?.snapshot?.relaunchesWindow(workspace.isSSH, window.activity?.agent) == true) {
                                { model.relaunch(machine.id, RelaunchScope.Window(machine.id, workspace.id, window.id)) }
                            } else null,
                        )
                    }
                    Level.MACHINE -> if (machine != null) MachineBoxesScreen(
                        machine = machine, connection = connection ?: MachinesViewModel.Connection(),
                        focusWorkspaceID = state.selectedWorkspace, noticeLink = state.notificationLinks[machine.id],
                        overrides = overrides, hostKeepsOrder = state.hostKeepsOrder[machine.id],
                        onBack = model::back,
                        onEnableNotices = { onEnableNotifications(machine.id) }, onDisableNotices = { model.disableNotifications(machine.id) },
                        onConnect = { model.connect(machine) }, onCreateWorkspace = { model.showCreate(false) },
                        onCreateWindow = model::createWindowIn, onOpenWindow = model::openWindow,
                        onToggleWorkspacePin = model::toggleWorkspacePinned,
                        onToggleWindowPin = { windowID, workspaceID -> model.toggleWindowPinned(windowID, workspaceID) },
                        onMoveWorkspace = model::moveWorkspace,
                        onMoveWindow = { windowID, delta, workspaceID -> model.moveWindow(windowID, delta, workspaceID) },
                        // Solo se ofrece si el equipo dice que sabe hacerlo. Un equipo antiguo no
                        // enseña la acción, en vez de enseñarla y tragársela.
                        onRelaunch = if (connection?.snapshot?.relaunches == true) {
                            { scope -> model.relaunch(machine.id, scope) }
                        } else null,
                        // Igual: sin `box_close` no se ofrece cerrar, en vez de ofrecerlo y fallar.
                        onCloseWorkspace = if (connection?.snapshot?.closesBoxes == true) model::closeWorkspace else null,
                        onCloseWindow = if (connection?.snapshot?.closesBoxes == true) model::closeWindow else null,
                        menu = {
                            MachineMenu(
                                canRelaunchAll = connection?.snapshot?.relaunches == true,
                                onEdit = { model.showEdit(machine) },
                                onRelaunchAll = { model.relaunch(machine.id, RelaunchScope.Machine(machine.id)) },
                                onRemove = { removing = machine },
                            )
                        },
                    )
                    Level.LIST -> PullToRefreshBox(
                        isRefreshing = state.refreshing,
                        onRefresh = { model.refreshMachineStates(force = true) },
                    ) {
                        val now = remember(state.connections) { System.currentTimeMillis() / 1000 }
                        val digest = remember(state.machines, state.connections, now) {
                            ActivityDigest.of(
                                state.machines, state.connections.mapValues { it.value.snapshot },
                                connected = state.connections.filterValues { it.connected }.keys, nowEpochSeconds = now,
                            )
                        }
                        DesignedHome(
                            model = HomeModel(
                                machines = state.machines.map { saved ->
                                    val link = state.connections[saved.id]
                                    HomeMachine(
                                        machine = saved,
                                        state = when {
                                            link?.connected == true -> MachineState.CONNECTED
                                            link?.checking == true -> MachineState.CHECKING
                                            else -> MachineState.SAVED
                                        },
                                        summary = summaries[saved.id] ?: HomeSummary(1, 0, 0, 0, 0),
                                    )
                                },
                                total = HomeSummary.total(state.machines.map { summaries[it.id] ?: HomeSummary(1, 0, 0, 0, 0) }),
                                activity = digest,
                                greeting = remember { Greeting.at(Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) },
                                nowEpochSeconds = now,
                                refreshing = state.refreshing,
                                troubled = troubled,
                            ),
                            actions = HomeActions(
                                onMenu = { scope.launch { drawer.open() } },
                                onRefresh = { model.refreshMachineStates(force = true) },
                                onDiagnostics = { model.showDiagnostics(true) },
                                onAdd = model::showAdd,
                                onSelectMachine = model::selectMachine,
                                onOpenWindow = model::openNotice,
                                onFiles = { sendingFiles = true }, onHistory = { historyOpen = true },
                                onNotices = { noticesOpen = true }, onSettings = { scope.launch { drawer.open() } },
                            ),
                        )
                    }
                }
            }
        }
    }
    }
    // Sin `?.let`: el informe se abre siempre. Antes dependía de poder leer el entorno, así que
    // un dato ilegible dejaba el botón sin hacer nada —o peor, tiraba la app al leerlo aquí en
    // pleno dibujado—. Lo que no se pueda leer sale como desconocido y el resto del informe se
    // enseña igual.
    if (state.diagnosticsOpen) {
        DiagnosticDialog(
            environment = state.diagnosticEnvironment,
            events = model.connectionEvents(),
            crashes = state.crashes,
            connectedNow = state.machines.filter { state.connections[it.id]?.connected == true }.map { it.name }.toSet(),
            notice = state.diagnosticsNotice,
            onCopy = model::copyDiagnostics,
            // No se cierra al compartir: si el selector no abre, hace falta seguir aquí para
            // poder copiar. Cerrarlo dejaba a quien lo pulsó sin informe y sin explicación.
            onShare = model::shareDiagnostics,
            // Enviar al equipo se ofrecerá cuando haya a dónde; compartir siempre funciona,
            // y este informe nace justamente de no haber conexión.
            onSend = null,
            onDismiss = { model.forgetCrashes(); model.showDiagnostics(false) },
        )
    }
    state.relaunch?.let { relaunch ->
        RelaunchDialog(relaunch, onConfirm = model::confirmRelaunch, onDismiss = model::dismissRelaunch)
    }
    state.windowDetails?.let { details ->
        WindowDetailsDialog(details, onCopy = model::copyResumeCommand, onDismiss = model::dismissWindowDetails)
    }
    if (state.showingSettings || settingsPage != null) {
        val inboxCandidates = state.machines.map { saved ->
            val link = state.connections[saved.id]
            InboxCandidate(saved, connected = link?.connected == true, keepsInbox = link?.snapshot?.keepsInbox == true)
        }
        SettingsSheet(
            state.settings, transcribers, dictation, model::updateSettings,
            onDismiss = { settingsPage = null; model.dismissSettings() },
            inbox = inbox, inboxCandidates = inboxCandidates, dictationHistory = dictationHistory, page = settingsPage,
        )
    }
    if (historyOpen && dictationHistory != null) {
        StandaloneHistorySheet(dictationHistory, state.settings.dictationLanguage.code, state.settings.pickedTranscriber) { historyOpen = false }
    }
    if (noticesOpen) {
        NotificationsSheet(
            machines = state.machines,
            connected = { state.connections[it.id]?.connected == true },
            links = state.notificationLinks,
            onEnable = { onEnableNotifications(it.id) },
            onDisable = { model.disableNotifications(it.id) },
            onDismiss = { noticesOpen = false },
        )
    }
    if (state.adding) MachineSheet(state.saving, state.formError, onDismiss = model::dismissAdd, onSave = model::saveMachine)
    state.editing?.let { target ->
        MachineSheet(state.saving, state.formError, machine = target, onDismiss = model::dismissEdit, onSave = model::saveMachine)
    }
    state.creation?.let { CreateResourceSheet(it, state.creating, state.creationError, model::dismissCreate, model::create) }
    removing?.let { target ->
        AlertDialog(
            onDismissRequest = { removing = null },
            containerColor = UniTheme.colors.surfaceRaised,
            icon = { Icon(Icons.Rounded.DeleteOutline, null, tint = UniTheme.colors.danger) },
            title = { Text(stringResource(R.string.remove_title)) },
            text = { Text(stringResource(R.string.remove_note), color = UniTheme.colors.muted) },
            confirmButton = { TextButton(onClick = { model.removeMachine(target); removing = null }) { Text(stringResource(R.string.remove), color = UniTheme.colors.danger) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun AppHeader(
    compact: Boolean, title: String, subtitle: String, showBack: Boolean, onBack: () -> Unit,
    monogramSeed: String?, pill: Pair<String, PillTone>?, actions: @Composable () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = if (compact) 2.dp else 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showBack) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back)) }
        else Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.padding(start = 8.dp).size(44.dp))
        if (monogramSeed != null && !compact) BoxMonogram(monogramSeed, Modifier.padding(start = 4.dp), size = 40.dp, selected = true)
        // Inside a machine the title and subtitle are names and addresses: identifier type.
        val identifier = if (showBack) UniTheme.type.identifierFamily else null
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(title, style = if (compact) MaterialTheme.typography.titleMedium else MaterialTheme.typography.titleLarge, fontFamily = identifier, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(subtitle, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelSmall, fontFamily = identifier, color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                // The state pill shares the subtitle line so the machine name keeps its full width.
                if (pill != null && !compact) StatusPill(pill.first, pill.second)
            }
        }
        actions()
    }
}

@Composable
fun ErrorNotice(message: Int, onDismiss: () -> Unit) = ErrorNotice(stringResource(message), onDismiss)

/** The same notice for a failure told in more than one sentence; see ``ActionNotice``. */
@Composable
fun ErrorNotice(notice: ActionNotice, onDismiss: () -> Unit) = ErrorNotice(
    listOfNotNull(stringResource(notice.message), notice.detail, notice.followUp?.let { stringResource(it) }).joinToString(" "),
    onDismiss,
)

@Composable
private fun ErrorNotice(text: String, onDismiss: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(horizontal = UniTheme.spacing.page, vertical = 4.dp), color = MaterialTheme.colorScheme.errorContainer, shape = UniTheme.shapes.card) {
        Row(Modifier.padding(start = 16.dp, top = 6.dp, bottom = 6.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall)
            IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.dismiss), tint = MaterialTheme.colorScheme.onErrorContainer) }
        }
    }
}

/** The machine's overflow menu: edit, relaunch every AI of the machine, remove. */
@Composable
private fun MachineMenu(canRelaunchAll: Boolean, onEdit: () -> Unit, onRelaunchAll: () -> Unit, onRemove: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Rounded.MoreVert, stringResource(R.string.machine_menu), tint = UniTheme.colors.muted) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = UniTheme.colors.surfaceRaised) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.edit_machine)) },
                leadingIcon = { Icon(Icons.Rounded.Edit, null, tint = UniTheme.colors.accent) },
                onClick = { open = false; onEdit() },
            )
            // El alcance de equipo entero vive aquí y no en la pulsación larga de un espacio:
            // pedir «todas» debe costar un gesto distinto que pedir «estas».
            if (canRelaunchAll) DropdownMenuItem(
                text = { Text(stringResource(R.string.relaunch_all_agents)) },
                leadingIcon = { Icon(Icons.Rounded.RestartAlt, null, tint = UniTheme.colors.accent) },
                onClick = { open = false; onRelaunchAll() },
            )
            DropdownMenuItem(
                text = { Text(stringResource(R.string.remove), color = UniTheme.colors.danger) },
                leadingIcon = { Icon(Icons.Rounded.DeleteOutline, null, tint = UniTheme.colors.danger) },
                onClick = { open = false; onRemove() },
            )
        }
    }
}

/** How often the home looks at the machines again while it is on screen. */
private const val HOME_REFRESH_MILLIS = 15_000L
