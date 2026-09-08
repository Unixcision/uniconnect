package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineClient
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.MachineDraft
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineRepository
import com.unixcision.uniconnect.android.domain.NoticeNameCatalog
import com.unixcision.uniconnect.android.domain.DraftRepository
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.MachineSnapshot
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import com.unixcision.uniconnect.android.domain.TerminalTarget
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.domain.WheelBudget
import com.unixcision.uniconnect.android.domain.MachineUpdate
import com.unixcision.uniconnect.android.domain.ResourceCreation
import com.unixcision.uniconnect.android.domain.NotificationConnectionControl
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.domain.PtyEvent
import com.unixcision.uniconnect.android.domain.TerminalAttachment
import com.unixcision.uniconnect.android.domain.vt.GeometryFollower
import com.unixcision.uniconnect.android.domain.vt.TerminalEmulator
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.launch

class MachinesViewModel(
    private val repository: MachineRepository,
    private val client: MachineClient,
    private val notificationControl: NotificationConnectionControl,
    private val settingsRepository: SettingsRepository,
    private val noticeNames: NoticeNameCatalog,
    private val drafts: DraftRepository,
) : ViewModel() {
    data class Connection(val checking: Boolean = false, val connected: Boolean = false, val snapshot: MachineSnapshot? = null, val error: Int? = null)
    /** A phone-sized tmux client attached to the selected window; the emulator lives in the model. */
    data class RealTerminal(
        val snapshot: TerminalSnapshot? = null, val applicationCursorKeys: Boolean = false,
        /** Whether tmux is showing its copy-mode indicator, i.e. the pane ignores typing. */
        val copyMode: Boolean = false,
        val connecting: Boolean = true, val ended: Boolean = false, val error: Int? = null, val errorDetail: String? = null,
    )
    data class State(
        val machines: List<Machine> = emptyList(), val loading: Boolean = true, val error: Int? = null,
        val adding: Boolean = false, val saving: Boolean = false, val formError: Int? = null,
        /** The machine whose address is being edited, if any; the form is shared with adding. */
        val editing: Machine? = null,
        val selectedMachine: String? = null, val selectedWorkspace: String? = null, val selectedWindow: String? = null,
        val connections: Map<String, Connection> = emptyMap(),
        /** Whether the list is asking every machine whether it answers right now. */
        val refreshing: Boolean = false,
        /** The user's own preferences; defaults until the stored ones are read. */
        val settings: AppSettings = AppSettings(),
        /** Whether the settings sheet is open. */
        val showingSettings: Boolean = false,
        /** Set when going to the background closed a real terminal that should come back. */
        val resumeRealTerminal: Boolean = false,
        /** The reading and magnification in use, kept across a re-attach; null means the setting. */
        val terminalView: TerminalView? = null,
        val terminalZoom: Float = 1f,
        /** What is typed in the composer of the selected window and not sent yet. */
        val draft: String = "",
        val terminal: TerminalSnapshot? = null, val terminalLoading: Boolean = false,
        val terminalError: Int? = null, val terminalErrorDetail: String? = null, val inputSending: Boolean = false, val reconnecting: Boolean = false,
        val creation: CreationContext? = null, val creating: Boolean = false, val creationError: Int? = null,
        val notificationLinks: Map<String, NotificationLinkState> = emptyMap(),
        val realTerminal: RealTerminal? = null,
        /** Machines whose host has no attach RPC yet; the mirror is used without asking again. */
        val attachUnsupported: Set<String> = emptySet(),
        /** Why the last automatic attach fell back to the mirror, shown so silence is not the answer. */
        val attachFallbackDetail: String? = null,
    )
    private val mutableState = MutableStateFlow(State())
    val state = mutableState.asStateFlow()
    private val requests = mutableMapOf<String, Job>()
    private var resumeMachineID: String? = null
    private var foreground = true
    private var noticeRoute: NoticeRoute? = null

    init {
        viewModelScope.launch {
            repository.machines.catch { mutableState.update { it.copy(loading = false, error = R.string.load_error) } }
                .collect { machines ->
                    mutableState.update { it.copy(machines = machines, loading = false) }
                    openPendingNoticeMachine()
                    if (state.value.selectedMachine == null) refreshMachineStates()
                }
        }
        viewModelScope.launch { notificationControl.states.collect { links -> mutableState.update { it.copy(notificationLinks = links) } } }
        viewModelScope.launch { settingsRepository.settings.collect { stored -> mutableState.update { it.copy(settings = stored) } } }
        // The activity is in the foreground when this model is built, so re-arming the saved links is allowed.
        notificationControl.restore()
    }

    private var probeJob: Job? = null

    /**
     * Refreshes the machine list's real state. Each saved machine is asked once, in parallel,
     * so the list shows connected/pending/offline instead of always "saved". Reading the tree
     * never creates a terminal or changes anything on the desktop.
     */
    fun refreshMachineStates(force: Boolean = false) {
        // List screen only: a probe must never race the live connection of an open machine.
        if (!foreground || state.value.selectedMachine != null) return
        // Asking every machine on its own is a preference; asking because the user asked is not.
        if (!force && !state.value.settings.probeOnOpen) return
        if (probeJob?.isActive == true) {
            // Asking again on purpose replaces the round already in flight; without this an
            // automatic probe would swallow the pull the user just made.
            if (!force) return
            probeJob?.cancel()
        }
        val machines = state.value.machines.filter { requests[it.id]?.isActive != true }
        if (machines.isEmpty()) return
        mutableState.update { current ->
            current.copy(refreshing = true, connections = current.connections + machines.associate { machine ->
                machine.id to (current.connections[machine.id] ?: Connection()).copy(checking = true)
            })
        }
        probeJob = viewModelScope.launch {
            try {
            machines.map { machine ->
                async {
                    // A probe result is only ever applied while the list is still what the user sees.
                    fun stale() = state.value.selectedMachine != null || requests[machine.id]?.isActive == true
                    try {
                        val snapshot = client.probe(machine)
                        noticeNames.remember(machine.id, snapshot)
                        mutableState.update { if (stale()) it else it.copy(connections = it.connections + (machine.id to Connection(connected = true, snapshot = snapshot))) }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) {
                        val code = (failure as? MachineFailure.Rejected)?.code
                        val message = if (code == "approval_required") R.string.approval_required else R.string.connection_error
                        mutableState.update { current ->
                            if (stale()) current
                            else current.copy(connections = current.connections + (machine.id to Connection(snapshot = current.connections[machine.id]?.snapshot, error = message)))
                        }
                    }
                }
            }.awaitAll()
            } finally {
                // Runs on cancellation too, so a replaced round never leaves the list spinning.
                mutableState.update { it.copy(refreshing = false) }
            }
        }
    }

    /** Remembers how the reader is looking at this window, so a re-attach does not reset it. */
    fun setTerminalView(view: TerminalView) { mutableState.update { it.copy(terminalView = view, terminalZoom = 1f) } }
    fun setTerminalZoom(zoom: Float) { mutableState.update { it.copy(terminalZoom = zoom) } }

    fun showSettings() { mutableState.update { it.copy(showingSettings = true) } }
    fun dismissSettings() { mutableState.update { it.copy(showingSettings = false) } }
    /** Stores a changed preference; the screen re-reads it from the repository's own flow. */
    fun updateSettings(settings: AppSettings) { viewModelScope.launch { settingsRepository.update(settings) } }

    fun showAdd() { mutableState.update { it.copy(adding = true, formError = null) } }
    fun dismissAdd() { if (!state.value.saving) mutableState.update { it.copy(adding = false, formError = null) } }
    /** Opens the same form on an existing machine, so a moved host is corrected instead of re-added. */
    fun showEdit(machine: Machine) { mutableState.update { it.copy(editing = machine, formError = null) } }
    fun dismissEdit() { if (!state.value.saving) mutableState.update { it.copy(editing = null, formError = null) } }
    fun dismissError() { mutableState.update { it.copy(error = null) } }
    fun notificationPermissionDenied() { mutableState.update { it.copy(error = R.string.notice_permission_denied) } }
    fun enableNotifications(machineID: String) {
        if (state.value.connections[machineID]?.connected == true) notificationControl.enable(machineID)
    }
    fun disableNotifications(machineID: String) { notificationControl.disable(machineID) }
    fun openNotice(route: NoticeRoute) { noticeRoute = route; openPendingNoticeMachine() }

    private fun openPendingNoticeMachine() {
        val route = noticeRoute ?: return
        if (state.value.loading) return
        val machine = state.value.machines.firstOrNull { it.id == route.machineID }
        if (machine == null) { noticeRoute = null; mutableState.update { it.copy(error = R.string.notice_target_missing) }; return }
        stopObserving()
        mutableState.update { it.copy(selectedMachine = machine.id, selectedWorkspace = null, selectedWindow = null, terminal = null) }
        startObserving(machine, force = true)
    }
    fun pauseLiveConnection() {
        foreground = false
        // Leaving the app closes the attached client, but the intention to be attached survives:
        // coming back used to drop the reader into the mirror because the screen had already
        // recorded that it tried once.
        val wasAttached = state.value.realTerminal != null
        stopRealTerminal()
        if (wasAttached) mutableState.update { it.copy(resumeRealTerminal = true) }
        resumeMachineID = state.value.selectedMachine?.takeIf { requests[it]?.isActive == true }
        stopObserving()
    }
    fun resumeLiveConnection() {
        foreground = true
        if (state.value.selectedMachine == null) refreshMachineStates()
        val id = resumeMachineID ?: return
        resumeMachineID = null
        if (state.value.selectedMachine == id) state.value.machines.firstOrNull { it.id == id }?.let(::connect)
    }
    fun showCreate(inWorkspace: Boolean) {
        val current = state.value
        val machineID = current.selectedMachine ?: return
        val connection = current.connections[machineID]?.takeIf { it.connected } ?: return
        val workspaces = connection.snapshot?.workspaces ?: return
        val workspace = if (inWorkspace) workspaces.firstOrNull { it.id == current.selectedWorkspace && it.isSSH != null } ?: return else null
        mutableState.update { it.copy(creation = CreationContext(machineID, workspace, workspaces.filter { box -> box.isSSH == true }), creationError = null) }
    }
    fun dismissCreate() { if (!state.value.creating) mutableState.update { it.copy(creation = null, creationError = null) } }

    fun create(request: ResourceCreation) {
        val current = state.value
        val context = current.creation ?: return
        if (current.creating) return
        val latestWorkspace = current.connections[context.machineID]?.snapshot?.workspaces?.firstOrNull { it.id == context.workspace?.id }
        if (!request.isValid() || (request is ResourceCreation.Terminal &&
                    (latestWorkspace == null || !request.isAllowedIn(latestWorkspace)))) {
            mutableState.update { it.copy(creationError = R.string.creation_invalid) }; return
        }
        val machine = current.machines.firstOrNull { it.id == context.machineID } ?: return
        if (current.connections[machine.id]?.connected != true) { mutableState.update { it.copy(creationError = R.string.connection_error) }; return }
        mutableState.update { it.copy(creating = true, creationError = null) }
        viewModelScope.launch {
            try {
                val result = client.create(machine, request)
                // Second step of "new workspace": the host confirmed an empty box, so ask how its
                // first window opens instead of assuming a plain terminal. An older host that still
                // spawned one terminal simply skips the question.
                val created = result.snapshot.workspaces.firstOrNull { it.id == result.workspaceID }
                val askFirstWindow = request is ResourceCreation.Workspace && !request.initialTerminal &&
                    created != null && created.isSSH != null && created.windows.isEmpty()
                val nextCreation = if (askFirstWindow) CreationContext(
                    machine.id, created, result.snapshot.workspaces.filter { box -> box.isSSH == true }, firstWindow = true,
                ) else null
                noticeNames.remember(machine.id, result.snapshot)
                mutableState.update { it.copy(creating = false, creation = nextCreation, creationError = null,
                    connections = it.connections + (machine.id to Connection(connected = true, snapshot = result.snapshot)),
                    selectedMachine = machine.id, selectedWorkspace = result.workspaceID, selectedWindow = result.windowID,
                    terminal = null, terminalError = null, terminalLoading = result.windowID != null,
                ) }
                startObserving(machine, force = true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                val code = (failure as? MachineFailure.Rejected)?.code
                mutableState.update { it.copy(creating = false, creationError = if (code == "invalid_params" || code == "create_failed") R.string.creation_rejected else R.string.creation_uncertain) }
            }
        }
    }
    fun selectMachine(id: String) {
        probeJob?.cancel()
        stopObserving()
        mutableState.update { it.copy(selectedMachine = id, selectedWorkspace = null, selectedWindow = null, terminal = null) }
        if (state.value.connections[id]?.snapshot != null) state.value.machines.firstOrNull { it.id == id }?.let(::connect)
    }
    fun selectWorkspace(id: String) { mutableState.update { it.copy(selectedWorkspace = id, selectedWindow = null) } }
    /** Opens a window. The reading resets to the setting, since it belonged to the previous one. */
    fun selectWindow(id: String) {
        stopRealTerminal()
        draftJob?.cancel(); draftJob = null
        mutableState.update { it.copy(selectedWindow = id, terminal = null, terminalView = null, terminalZoom = 1f, draft = "") }
        val machineID = state.value.selectedMachine
        if (machineID != null) viewModelScope.launch {
            val stored = drafts.load(machineID, id)
            // Only if the reader is still on this window and has not typed anything meanwhile.
            mutableState.update { if (it.selectedWindow == id && it.draft.isEmpty()) it.copy(draft = stored) else it }
        }
        refreshTerminal()
    }

    private var draftJob: Job? = null

    /** Mirrors the composer: the screen shows it at once, disk catches up a moment later. */
    fun updateDraft(text: String) {
        mutableState.update { it.copy(draft = text) }
        val machineID = state.value.selectedMachine ?: return
        val windowID = state.value.selectedWindow ?: return
        draftJob?.cancel()
        draftJob = viewModelScope.launch {
            // Bounded, intended delay: one write per pause in typing instead of one per keystroke.
            delay(DRAFT_SAVE_DELAY_MILLIS)
            drafts.save(machineID, windowID, text)
        }
    }
    fun back() { stopRealTerminal(); mutableState.update {
        when {
            it.selectedWindow != null -> it.copy(selectedWindow = null, terminal = null, terminalLoading = false, terminalError = null, terminalErrorDetail = null, attachFallbackDetail = null, terminalView = null, terminalZoom = 1f)
            it.selectedWorkspace != null -> it.copy(selectedWorkspace = null)
            else -> it.copy(selectedMachine = null)
        }
    }; state.value.selectedMachine?.let { id -> state.value.machines.firstOrNull { it.id == id }?.let { startObserving(it, force = true) } } ?: run { stopObserving(); refreshMachineStates() } }

    /**
     * Saves the form, either as a new machine or over the one being edited.
     *
     * Editing keeps the machine's id, so its notification link, selection and history survive a
     * change of address; only the address itself decides whether the live connection is rebuilt.
     */
    fun saveMachine(name: String, address: String, port: String) {
        if (state.value.saving) return
        val edited = state.value.editing
        val draft = MachineDraft(name, address, port)
        val problem = draft.problem(state.value.machines, edited?.id)
        if (problem != null) {
            val error = when (problem) {
                MachineDraft.Problem.NAME -> R.string.name_required
                MachineDraft.Problem.PORT -> R.string.port_invalid
                MachineDraft.Problem.ADDRESS -> R.string.address_invalid
                MachineDraft.Problem.DUPLICATE -> R.string.duplicate_machine
            }
            mutableState.update { it.copy(formError = error) }
            return
        }
        mutableState.update { it.copy(saving = true, formError = null) }
        viewModelScope.launch {
            try {
                val machine = draft.machine(edited?.id ?: UUID.randomUUID().toString())
                repository.save(machine)
                // A renamed machine is the same host: nothing about the connection changes. A moved
                // one is not, so anything read from the old address has to go.
                val moved = edited != null && edited.endpoint != machine.endpoint
                mutableState.update {
                    it.copy(
                        saving = false, adding = false, editing = null,
                        selectedWorkspace = if (moved) null else it.selectedWorkspace,
                        selectedWindow = if (moved) null else it.selectedWindow,
                        connections = if (moved) it.connections - machine.id else it.connections,
                    )
                }
                if (moved) {
                    requests.remove(machine.id)?.cancel()
                    if (state.value.selectedMachine == machine.id) { stopRealTerminal(); startObserving(machine, force = true) }
                    else refreshMachineStates()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutableState.update { it.copy(saving = false, formError = R.string.save_error) } }
        }
    }

    fun removeMachine(machine: Machine) {
        requests.remove(machine.id)?.cancel()
        if (machine.id in state.value.notificationLinks) notificationControl.disable(machine.id)
        viewModelScope.launch {
            try {
                repository.remove(machine.id)
                mutableState.update { it.copy(selectedMachine = null, selectedWorkspace = null, selectedWindow = null, connections = it.connections - machine.id) }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutableState.update { it.copy(error = R.string.remove_error) } }
        }
    }

    fun connect(machine: Machine) = startObserving(machine, force = false)

    private fun startObserving(machine: Machine, force: Boolean) {
        if (!foreground) {
            resumeMachineID = machine.id
            mutableState.update { it.copy(connections = it.connections + (machine.id to (it.connections[machine.id] ?: Connection()).copy(connected = false, checking = false))) }
            return
        }
        if (!force && requests[machine.id]?.isActive == true) return
        requests.remove(machine.id)?.cancel()
        val selected = state.value
        val target = if (selected.selectedWorkspace != null && selected.selectedWindow != null) TerminalTarget(selected.selectedWorkspace, selected.selectedWindow) else null
        mutableState.update { it.copy(connections = it.connections + (machine.id to (it.connections[machine.id] ?: Connection()).copy(checking = true, connected = false, error = null))) }
        requests[machine.id] = viewModelScope.launch {
            var retry = 0
            var wasConnected = false
            while (true) {
                try {
                    client.observe(machine, target).collect { update ->
                        if (target == null || update is MachineUpdate.Terminal) { wasConnected = true; retry = 0 }
                        when (update) {
                            is MachineUpdate.Workspaces -> {
                                noticeNames.remember(machine.id, update.snapshot)
                                mutableState.update { current ->
                                    val creation = current.creation
                                    val refreshedCreation = if (creation?.machineID == machine.id && creation.workspace != null) {
                                        update.snapshot.workspaces.firstOrNull { it.id == creation.workspace.id }
                                            ?.let { creation.copy(workspace = it) }
                                    } else creation
                                    val workspaces = update.snapshot.workspaces
                                    val selectedWorkspace = current.selectedWorkspace?.takeIf { id -> workspaces.any { it.id == id } }
                                    val selectedWindow = current.selectedWindow?.takeIf { id ->
                                        workspaces.firstOrNull { it.id == selectedWorkspace }?.windows?.any { it.id == id } == true
                                    }
                                    // The desktop tree is authoritative: a closed window must not keep a dead screen open.
                                    val lostSelection = current.selectedMachine == machine.id &&
                                        (selectedWorkspace != current.selectedWorkspace || selectedWindow != current.selectedWindow)
                                    current.copy(
                                        connections = current.connections + (machine.id to Connection(connected = true, snapshot = update.snapshot)),
                                        creation = refreshedCreation,
                                        selectedWorkspace = if (lostSelection) selectedWorkspace else current.selectedWorkspace,
                                        selectedWindow = if (lostSelection) selectedWindow else current.selectedWindow,
                                        terminal = if (lostSelection) null else current.terminal,
                                        terminalLoading = if (lostSelection) false else current.terminalLoading,
                                        error = if (lostSelection) R.string.window_gone else current.error,
                                    )
                                }
                                val route = noticeRoute?.takeIf { it.machineID == machine.id }
                                if (route != null) {
                                    noticeRoute = null
                                    val workspace = update.snapshot.workspaces.firstOrNull { it.id == route.workspaceID }
                                    val window = workspace?.windows?.firstOrNull { it.id == route.windowID }
                                    mutableState.update { it.copy(selectedWorkspace = workspace?.id, selectedWindow = window?.id,
                                        error = if (workspace == null || (route.windowID != null && window == null)) R.string.notice_target_missing else null) }
                                    if (window != null) refreshTerminal()
                                }
                            }
                            is MachineUpdate.Terminal -> mutableState.update { if (it.selectedMachine == machine.id && it.selectedWindow == target?.windowID) it.copy(terminal = update.snapshot, terminalLoading = false, terminalError = null) else it }
                        }
                    }
                    break
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) {
                    val rejected = failure as? MachineFailure.Rejected
                    val code = rejected?.code
                    // Keep the host's own code and message: a bare "could not connect" hides surface_unavailable etc.
                    val detail = rejected?.let { listOfNotNull(it.code.takeIf(String::isNotBlank), it.detail).joinToString(" · ") }?.takeIf { it.isNotBlank() }
                    val incompatible = failure is MachineFailure.ProtocolMismatch || failure is MachineFailure.UnsupportedTerminal
                    val notReady = failure is MachineFailure.TerminalNotReady
                    // Only an answer that cannot improve by asking again is final. Opening a window
                    // races the previous stream's teardown on the host, so the first failures are
                    // retried quietly instead of leaving a dead screen that needs a manual refresh.
                    val fatal = incompatible || code in setOf("approval_required", "unauthorized", "forbidden", "not_found", "process_exited")
                    val attemptsLeft = if (wasConnected) Int.MAX_VALUE else if (notReady) 1 else INITIAL_ATTEMPTS
                    val stop = fatal || retry >= attemptsLeft
                    val message = when {
                        !stop -> R.string.connection_reconnecting
                        notReady -> R.string.terminal_not_ready
                        incompatible -> R.string.incompatible_terminal
                        code == "approval_required" -> R.string.approval_required
                        else -> R.string.connection_error
                    }
                    mutableState.update { it.copy(
                        connections = it.connections + (machine.id to (it.connections[machine.id] ?: Connection()).copy(checking = !stop, connected = false, error = message)),
                        terminalLoading = false, terminalError = if (target != null) message else it.terminalError,
                        terminalErrorDetail = if (target != null) detail else it.terminalErrorDetail,
                    ) }
                    if (stop) break
                    // Quick first retries so opening a window feels immediate; slower once it is a real outage.
                    delay(if (wasConnected) minOf(1_000L shl retry.coerceAtMost(4), 15_000L) else 400L)
                    retry += 1
                }
            }
        }
    }

    private fun stopObserving() {
        requests.values.forEach { it.cancel() }
        requests.clear()
        mutableState.update { it.copy(connections = it.connections.mapValues { (_, connection) -> connection.copy(connected = false, checking = false) }) }
    }

    fun refreshTerminal() {
        val current = state.value
        val machine = current.machines.firstOrNull { it.id == current.selectedMachine } ?: return
        current.selectedWorkspace ?: return
        current.selectedWindow ?: return
        mutableState.update { it.copy(terminalLoading = true, terminalError = null, terminalErrorDetail = null) }
        startObserving(machine, force = true)
    }

    /** Reattaches the selected window's durable session on the desktop, then replays its screen. */
    fun reconnectWindow() {
        val current = state.value
        if (current.reconnecting) return
        val machine = current.machines.firstOrNull { it.id == current.selectedMachine } ?: return
        val workspaceID = current.selectedWorkspace ?: return
        val windowID = current.selectedWindow ?: return
        // Allowed even after a failed replay: the request opens its own socket and reports its own outcome.
        mutableState.update { it.copy(reconnecting = true, terminalError = null, terminalErrorDetail = null) }
        viewModelScope.launch {
            try {
                client.reconnect(machine, workspaceID, windowID)
                mutableState.update { it.copy(reconnecting = false, terminal = null, terminalLoading = true) }
                startObserving(machine, force = true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                val rejected = failure as? MachineFailure.Rejected
                mutableState.update { it.copy(reconnecting = false,
                    terminalError = if (rejected?.code == "not_durable") R.string.reconnect_not_durable else R.string.reconnect_failed,
                    terminalErrorDetail = rejected?.let { listOfNotNull(it.code.takeIf(String::isNotBlank), it.detail).joinToString(" · ") }?.takeIf { it.isNotBlank() }) }
            }
        }
    }

    private var scrollAccumulator = 0
    private var scrollJob: Job? = null

    /** Scrolls the desktop viewport; gestures are coalesced so a fling becomes a few bounded requests. */
    fun scrollTerminal(deltaLines: Int) {
        if (deltaLines == 0) return
        val current = state.value
        val machine = current.machines.firstOrNull { it.id == current.selectedMachine } ?: return
        val workspaceID = current.selectedWorkspace ?: return
        val windowID = current.selectedWindow ?: return
        if (current.connections[machine.id]?.connected != true || current.terminal == null) return
        scrollAccumulator += deltaLines
        if (scrollJob?.isActive == true) return
        scrollJob = viewModelScope.launch {
            while (scrollAccumulator != 0) {
                val delta = scrollAccumulator.coerceIn(-1000, 1000)
                scrollAccumulator -= delta
                try { client.scroll(machine, workspaceID, windowID, delta) }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) {
                    scrollAccumulator = 0
                    // A host rejection is worth one visible note; transport hiccups stay silent.
                    (failure as? MachineFailure.Rejected)?.let { rejected ->
                        mutableState.update { it.copy(terminalError = R.string.scroll_failed,
                            terminalErrorDetail = listOfNotNull(rejected.code.takeIf(String::isNotBlank), rejected.detail).joinToString(" · ").takeIf { d -> d.isNotBlank() }) }
                    }
                    return@launch
                }
            }
        }
    }

    private var attachment: TerminalAttachment? = null
    private var attachJob: Job? = null
    private var reattachJob: Job? = null
    private var attachedAtNanos = 0L
    private var automaticReattaches = 0

    /**
     * Re-attaches the selected window at the size the emulator already has.
     *
     * Used by the Reconnect button and by the automatic retry: an attachment that the host ends
     * on its own (a burst of output over a slow link, a dropped socket) is not the reader leaving.
     */
    fun reconnectRealTerminal() {
        val columns = emulator?.screen?.columns ?: state.value.realTerminal?.snapshot?.columns ?: return
        val rows = emulator?.screen?.rows ?: state.value.realTerminal?.snapshot?.rows ?: return
        val machine = state.value.machines.firstOrNull { it.id == state.value.selectedMachine } ?: return
        reattachJob?.cancel(); reattachJob = null
        stopRealTerminal()
        // The host that ended the session often took the machine link down with it. Attaching on a
        // dead link only produced "could not connect": bring the machine back first, then attach.
        if (state.value.connections[machine.id]?.connected == true) {
            startRealTerminal(columns, rows, automatic = false)
            return
        }
        mutableState.update { it.copy(realTerminal = RealTerminal(connecting = true)) }
        reattachJob = viewModelScope.launch {
            connect(machine)
            // Bounded, intended wait: the observer reports the link as soon as the host answers.
            val linked = withTimeoutOrNull(RECONNECT_LINK_TIMEOUT_MILLIS) {
                state.first { it.connections[machine.id]?.connected == true }
            } != null
            mutableState.update { it.copy(realTerminal = null) }
            if (linked) startRealTerminal(columns, rows, automatic = false)
            else mutableState.update { it.copy(error = R.string.connection_error) }
        }
    }

    /** Schedules one automatic re-attach after the host ended the session, up to a small limit. */
    private fun scheduleReattach() {
        // A session that stayed up for a while earns fresh retries; a flapping one does not.
        if (System.nanoTime() - attachedAtNanos > REATTACH_RESET_NANOS) automaticReattaches = 0
        if (automaticReattaches >= MAX_AUTOMATIC_REATTACHES) return
        if (state.value.selectedMachine == null) return
        automaticReattaches += 1
        reattachJob?.cancel()
        reattachJob = viewModelScope.launch {
            // Bounded, intended pause: let the host settle before asking for the pane again.
            delay(REATTACH_DELAY_MILLIS)
            // The finished attachment has already been cleared by then; what matters is that no
            // newer one has started and the screen still shows the session as ended.
            if (attachJob?.isActive != true && state.value.realTerminal?.let { it.ended || it.error != null } == true) reconnectRealTerminal()
        }
    }
    private var emulator: TerminalEmulator? = null
    private val geometry = GeometryFollower()
    private var pendingGeometryJob: Job? = null

    /** Resizes this attachment's emulator and its host PTY; the call dies with the attachment. */
    private fun applyGeometry(terminal: TerminalEmulator, live: TerminalAttachment, columns: Int, rows: Int) {
        pendingGeometryJob?.cancel()
        terminal.resize(columns, rows)
        val frame = terminal.snapshot()
        mutableState.update { it.copy(realTerminal = it.realTerminal?.copy(snapshot = frame, copyMode = frame.inCopyMode)) }
        pendingGeometryJob = viewModelScope.launch {
            if (attachment === live) runCatching { live.resize(columns, rows) }
        }
    }

    /** Wakes up after the burst window to apply whatever the follower kept pending. */
    private fun scheduleGeometry(terminal: TerminalEmulator, live: TerminalAttachment, afterNanos: Long) {
        pendingGeometryJob?.cancel()
        pendingGeometryJob = viewModelScope.launch {
            // Bounded, intended delay: after the burst window there is, by definition, no burst.
            delay(afterNanos / 1_000_000 + 1)
            if (attachment !== live) return@launch
            val decision = geometry.onDeadline(terminal.screen.columns, terminal.screen.rows, System.nanoTime())
            if (decision is GeometryFollower.Decision.Apply) applyGeometry(terminal, live, decision.columns, decision.rows)
        }
    }

    /** Attaches a phone-sized tmux client to the selected window and mirrors it through the local emulator. */
    /** Attaches a phone-sized tmux client to the selected window and mirrors it through the local emulator. */
    fun startRealTerminal(columns: Int, rows: Int, automatic: Boolean = false) {
        val current = state.value
        if (current.realTerminal != null) return
        // The real terminal is the default way in; a host without the attach RPC falls back to the
        // mirror once and is not asked again for this machine.
        if (automatic && current.selectedMachine in current.attachUnsupported) return
        val machine = current.machines.firstOrNull { it.id == current.selectedMachine } ?: return
        val workspaceID = current.selectedWorkspace ?: return
        val windowID = current.selectedWindow ?: return
        if (current.connections[machine.id]?.connected != true) { mutableState.update { it.copy(error = R.string.connection_error) }; return }
        val terminal = TerminalEmulator(columns, rows)
        emulator = terminal
        mutableState.update { it.copy(attachFallbackDetail = null, resumeRealTerminal = false) }
        geometry.reset()
        mutableState.update { it.copy(realTerminal = RealTerminal(connecting = true)) }
        attachJob = viewModelScope.launch {
            var live: TerminalAttachment? = null
            try {
                live = client.attach(machine, workspaceID, windowID, columns, rows)
                attachment = live
                attachedAtNanos = System.nanoTime()
                if (live.columns != columns || live.rows != rows) terminal.resize(live.columns, live.rows)
                mutableState.update { it.copy(realTerminal = RealTerminal(snapshot = terminal.snapshot(), connecting = false)) }
                // Rendering is decoupled from reading. A busy TUI (Codex redrawing with a spinner)
                // pushes well over 100 KB/s; taking a full snapshot per chunk made this collector
                // slower than the network, the socket reader stalled behind it, and the host saw
                // its queue overflow and dropped the attachment. Now bytes are fed as they come and
                // the screen is published at most once per frame.
                var dirty = false
                val painter = launch {
                    while (isActive) {
                        // Bounded, intended pacing: one snapshot per ~frame, only when bytes arrived.
                        delay(RENDER_FRAME_MILLIS)
                        if (!dirty || attachment !== live) continue
                        dirty = false
                        val frame = terminal.snapshot()
                        mutableState.update { it.copy(realTerminal = it.realTerminal?.copy(snapshot = frame, copyMode = frame.inCopyMode, applicationCursorKeys = terminal.applicationCursorKeys)) }
                    }
                }
                try { live.events.buffer(Channel.UNLIMITED).collect { event ->
                    when (event) {
                        is PtyEvent.Output -> {
                            terminal.feed(event.bytes)
                            // Answer the program's queries (cursor position, device attributes) right away.
                            val answer = terminal.drainResponses()
                            if (answer.isNotEmpty()) runCatching { live.send(answer.toByteArray(Charsets.UTF_8)) }
                            dirty = true
                        }
                        is PtyEvent.Geometry -> {
                            // The host owns the geometry: match the phone's PTY to the canvas it
                            // reports so tmux stops padding rows the window does not have.
                            // GeometryFollower owns the burst and staleness rules and is unit-tested;
                            // here we only carry out its decision for this attachment.
                            when (val decision = geometry.onReport(
                                event.presentationColumns, event.presentationRows,
                                terminal.screen.columns, terminal.screen.rows, System.nanoTime(),
                            )) {
                                is GeometryFollower.Decision.Apply -> applyGeometry(terminal, live, decision.columns, decision.rows)
                                is GeometryFollower.Decision.Defer -> scheduleGeometry(terminal, live, decision.afterNanos)
                                GeometryFollower.Decision.Ignore -> pendingGeometryJob?.cancel()
                            }
                        }
                        PtyEvent.Exit -> {
                            mutableState.update { it.copy(realTerminal = it.realTerminal?.copy(ended = true, connecting = false)) }
                            scheduleReattach()
                        }
                    }
                } } finally {
                    painter.cancel()
                    // Whatever arrived after the last frame is shown before the screen goes quiet.
                    if (attachment === live) {
                        val frame = terminal.snapshot()
                        mutableState.update { it.copy(realTerminal = it.realTerminal?.copy(snapshot = frame, copyMode = frame.inCopyMode, applicationCursorKeys = terminal.applicationCursorKeys)) }
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                val rejected = failure as? MachineFailure.Rejected
                val unsupported = rejected?.code in setOf("method_not_found", "unknown_method", "not_supported", "unsupported")
                val message = when {
                    unsupported -> R.string.real_terminal_unavailable
                    rejected?.code == "not_durable" -> R.string.reconnect_not_durable
                    else -> R.string.real_terminal_failed
                }
                val detail = rejected?.let { listOfNotNull(it.code.takeIf(String::isNotBlank), it.detail).joinToString(" · ") }?.takeIf { it.isNotBlank() }
                mutableState.update { current ->
                    // Only a missing method means "this machine cannot do it"; a window without a
                    // durable target says nothing about the next one, so it is not remembered.
                    val remembered = if (unsupported && machine.id.isNotBlank()) current.attachUnsupported + machine.id else current.attachUnsupported
                    // An automatic attempt that fails returns to the mirror rather than leaving an
                    // empty real-terminal screen; only a mode the user asked for reports the reason.
                    // Falling back without a word made a refused attach look like a broken mode.
                    if (automatic) current.copy(realTerminal = null, attachUnsupported = remembered, attachFallbackDetail = detail ?: "attach")
                    else current.copy(realTerminal = RealTerminal(connecting = false, error = message, errorDetail = detail), attachUnsupported = remembered)
                }
            } finally {
                live?.close()
                if (attachment === live) attachment = null
            }
        }
    }

    fun stopRealTerminal() {
        // Leaving on purpose cancels any intention to come back attached; pausing re-arms it after.
        mutableState.update { it.copy(resumeRealTerminal = false) }
        reattachJob?.cancel(); reattachJob = null
        leaveCopyModeJob?.cancel(); leaveCopyModeJob = null
        wheelJob?.cancel(); wheelJob = null; wheelBudget.clear()
        pendingGeometryJob?.cancel(); pendingGeometryJob = null; geometry.reset()
        attachJob?.cancel(); attachJob = null
        attachment?.close(); attachment = null
        emulator = null
        if (state.value.realTerminal != null) mutableState.update { it.copy(realTerminal = null) }
    }

    /** Raw bytes to the attached client: keys, typed text, pasted text. */
    fun sendPty(text: String, withEnter: Boolean = false) {
        val live = attachment ?: return
        if (text.isEmpty()) return
        viewModelScope.launch {
            try {
                live.send(text.toByteArray(Charsets.UTF_8))
                // Same rule as the mirror: Return is a keypress of its own, never the tail of a paste.
                if (withEnter) { delay(ENTER_GAP_MILLIS); live.send("\r".toByteArray(Charsets.UTF_8)) }
            }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { mutableState.update { it.copy(error = R.string.input_failed) } }
        }
    }

    private var wheelJob: Job? = null
    private var leaveCopyModeJob: Job? = null

    /**
     * Walks the attached pane out of tmux's copy mode and back to the live screen.
     *
     * tmux leaves copy mode by itself once the wheel reaches the bottom, so this sends wheel steps
     * rather than a key. Reading the indicator cannot rule out that another client leaves the mode
     * first, and what arrives late is then handled by tmux's mouse handling and by the program
     * inside. Neither outcome is guaranteed, but a stray mouse event is the smaller of the two: a
     * stray `q` quits `less` or `top` on its own, with no Enter needed.
     *
     * This is provisional and frame-based. It is not a semantic cancellation, and the indicator
     * clearing is the only confirmation it has.
     *
     * It goes in short bursts and stops as soon as the indicator clears, so a shallow history
     * costs one burst instead of the deepest one imaginable, and it cancels any queued wheel work
     * first — otherwise the tap would wait behind every step a drag had already scheduled.
     */
    fun leaveCopyMode() {
        val live = attachment ?: return
        val terminal = emulator ?: return
        leaveCopyModeJob?.cancel()
        wheelJob?.cancel(); wheelJob = null; wheelBudget.clear()
        val sequence = terminal.encodeWheel(up = false, column = 0, row = 0).toByteArray(Charsets.UTF_8)
        leaveCopyModeJob = viewModelScope.launch {
            repeat(COPY_MODE_EXIT_BURSTS) {
                if (attachment !== live || !terminal.snapshot().inCopyMode) return@launch
                repeat(COPY_MODE_EXIT_STEPS) { step ->
                    if (attachment !== live) return@launch
                    runCatching { live.send(sequence) }.onFailure { return@launch }
                    if (step < COPY_MODE_EXIT_STEPS - 1) delay(WHEEL_GAP_MILLIS)
                }
                // Bounded, intended pause: tmux has to redraw before its indicator can be believed.
                delay(COPY_MODE_SETTLE_MILLIS)
            }
        }
    }

    /**
     * Wheel steps for the attached client; tmux turns them into copy-mode scrolling.
     *
     * Each step is written on its own: a burst of steps in a single write reads as pasted input, so
     * tmux acts on the first one (entering copy-mode) and ignores the rest, which is exactly how the
     * view used to freeze at the top of the history.
     */
    private val wheelBudget = WheelBudget()

    /**
     * Wheel steps for the attached client; tmux turns them into copy-mode scrolling.
     *
     * Requests only adjust a balance; a single drainer sends one step per gap while the balance
     * is not zero. Each step is its own write, because a burst in one write reads as pasted input
     * and tmux acts on the first step only.
     */
    fun wheelPty(up: Boolean, steps: Int, column: Int = 0, row: Int = 0) {
        val live = attachment ?: return
        val terminal = emulator ?: return
        wheelBudget.add(up, steps.coerceAtLeast(1))
        if (wheelJob?.isActive == true) return
        wheelJob = viewModelScope.launch {
            while (attachment === live) {
                val direction = wheelBudget.next() ?: break
                val sequence = terminal.encodeWheel(direction, column, row).toByteArray(Charsets.UTF_8)
                if (runCatching { live.send(sequence) }.isFailure) { wheelBudget.clear(); break }
                // Bounded, intended gap so each step is its own event rather than part of a paste.
                delay(WHEEL_GAP_MILLIS)
            }
        }
    }

    fun resizePty(columns: Int, rows: Int) {
        val terminal = emulator ?: return
        if (terminal.screen.columns == columns && terminal.screen.rows == rows) return
        terminal.resize(columns, rows)
        mutableState.update { it.copy(realTerminal = it.realTerminal?.copy(snapshot = terminal.snapshot())) }
        val live = attachment ?: return
        viewModelScope.launch { runCatching { live.resize(columns, rows) } }
    }

    override fun onCleared() { stopRealTerminal(); super.onCleared() }

    /**
     * Sends composed text and, with [withEnter], the Return key as a **separate** write.
     *
     * TUIs such as Codex or Claude Code treat a burst that ends in CR as pasted text and insert a
     * line break instead of submitting. A human's Return arrives on its own, so the key is written
     * after the text is acknowledged, with a short gap that closes the paste on the other side.
     */
    fun sendInput(text: String, withEnter: Boolean = false, onDelivered: (Boolean) -> Unit) {
        val current = state.value
        if (text.isEmpty() || current.inputSending) return
        val machine = current.machines.firstOrNull { it.id == current.selectedMachine } ?: return
        if (current.connections[machine.id]?.connected != true || current.terminal == null) return
        if (text.toByteArray(Charsets.UTF_8).size > 256 * 1024) { mutableState.update { it.copy(error = R.string.input_too_large) }; return }
        val workspaceID = current.selectedWorkspace ?: return
        val windowID = current.selectedWindow ?: return
        mutableState.update { it.copy(inputSending = true) }
        viewModelScope.launch {
            try {
                client.sendInput(machine, workspaceID, windowID, text)
                if (withEnter) {
                    // Bounded, intended gap: it is the pause that makes Return a keypress, not a paste.
                    delay(ENTER_GAP_MILLIS)
                    client.sendInput(machine, workspaceID, windowID, "\r")
                }
                mutableState.update { it.copy(inputSending = false) }
                onDelivered(true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                mutableState.update { it.copy(inputSending = false, error = R.string.input_failed) }
                onDelivered(false)
            }
        }
    }

    private companion object {
        /** Long enough for a TUI to close its paste window, short enough to feel immediate. */
        const val ENTER_GAP_MILLIS = 80L
        /** Gap between wheel steps so tmux reads each one as a separate event. */
        const val WHEEL_GAP_MILLIS = 16L
        /** How often the attached screen is published while bytes keep arriving (~40 fps). */
        const val RENDER_FRAME_MILLIS = 24L
        /** Automatic re-attach after the host ends a session: how long to wait, how many in a row. */
        const val REATTACH_DELAY_MILLIS = 1500L
        const val MAX_AUTOMATIC_REATTACHES = 2
        /** An attachment that lasted this long resets the automatic retry budget. */
        const val REATTACH_RESET_NANOS = 30_000_000_000L
        /** How long a reconnect waits for the machine link before giving up. */
        const val RECONNECT_LINK_TIMEOUT_MILLIS = 12_000L
        /** Pause in typing after which the draft is written to disk. */
        const val DRAFT_SAVE_DELAY_MILLIS = 250L
        /** Wheel steps per burst while leaving copy mode, and how many bursts at most. */
        const val COPY_MODE_EXIT_STEPS = 12
        const val COPY_MODE_EXIT_BURSTS = 40
        /** Time given to tmux to redraw before its indicator is read again. */
        const val COPY_MODE_SETTLE_MILLIS = 110L
        /** Retries allowed before a first connection is reported as failed. */
        const val INITIAL_ATTEMPTS = 3
    }
}
