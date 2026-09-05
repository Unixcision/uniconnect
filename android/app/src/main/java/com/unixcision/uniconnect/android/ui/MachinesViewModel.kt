package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineClient
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineRepository
import com.unixcision.uniconnect.android.domain.MachineSnapshot
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import com.unixcision.uniconnect.android.domain.TerminalTarget
import com.unixcision.uniconnect.android.domain.MachineUpdate
import com.unixcision.uniconnect.android.domain.ResourceCreation
import com.unixcision.uniconnect.android.domain.NotificationConnectionControl
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.NoticeRoute
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class MachinesViewModel(private val repository: MachineRepository, private val client: MachineClient, private val notificationControl: NotificationConnectionControl) : ViewModel() {
    data class Connection(val checking: Boolean = false, val connected: Boolean = false, val snapshot: MachineSnapshot? = null, val error: Int? = null)
    data class State(
        val machines: List<Machine> = emptyList(), val loading: Boolean = true, val error: Int? = null,
        val adding: Boolean = false, val saving: Boolean = false, val formError: Int? = null,
        val selectedMachine: String? = null, val selectedWorkspace: String? = null, val selectedWindow: String? = null,
        val connections: Map<String, Connection> = emptyMap(),
        val terminal: TerminalSnapshot? = null, val terminalLoading: Boolean = false,
        val terminalError: Int? = null, val terminalErrorDetail: String? = null, val inputSending: Boolean = false, val reconnecting: Boolean = false,
        val creation: CreationContext? = null, val creating: Boolean = false, val creationError: Int? = null,
        val notificationLinks: Map<String, NotificationLinkState> = emptyMap(),
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
                .collect { machines -> mutableState.update { it.copy(machines = machines, loading = false) }; openPendingNoticeMachine() }
        }
        viewModelScope.launch { notificationControl.states.collect { links -> mutableState.update { it.copy(notificationLinks = links) } } }
    }

    fun showAdd() { mutableState.update { it.copy(adding = true, formError = null) } }
    fun dismissAdd() { if (!state.value.saving) mutableState.update { it.copy(adding = false, formError = null) } }
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
        resumeMachineID = state.value.selectedMachine?.takeIf { requests[it]?.isActive == true }
        stopObserving()
    }
    fun resumeLiveConnection() {
        foreground = true
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
        stopObserving()
        mutableState.update { it.copy(selectedMachine = id, selectedWorkspace = null, selectedWindow = null, terminal = null) }
        if (state.value.connections[id]?.snapshot != null) state.value.machines.firstOrNull { it.id == id }?.let(::connect)
    }
    fun selectWorkspace(id: String) { mutableState.update { it.copy(selectedWorkspace = id, selectedWindow = null) } }
    fun selectWindow(id: String) { mutableState.update { it.copy(selectedWindow = id, terminal = null) }; refreshTerminal() }
    fun back() { mutableState.update {
        when {
            it.selectedWindow != null -> it.copy(selectedWindow = null, terminal = null, terminalLoading = false, terminalError = null, terminalErrorDetail = null)
            it.selectedWorkspace != null -> it.copy(selectedWorkspace = null)
            else -> it.copy(selectedMachine = null)
        }
    }; state.value.selectedMachine?.let { id -> state.value.machines.firstOrNull { it.id == id }?.let { startObserving(it, force = true) } } ?: stopObserving() }

    fun saveMachine(name: String, address: String, port: String) {
        if (state.value.saving) return
        val endpoint = MachineEndpoint.parse(address, port)
        val error = when {
            name.trim().length !in 1..80 || name.any { it.isISOControl() } -> R.string.name_required
            port.trim().toIntOrNull() !in 1..65535 -> R.string.port_invalid
            endpoint == null -> R.string.address_invalid
            state.value.machines.any { it.endpoint == endpoint } -> R.string.duplicate_machine
            else -> null
        }
        if (error != null) { mutableState.update { it.copy(formError = error) }; return }
        mutableState.update { it.copy(saving = true, formError = null) }
        viewModelScope.launch {
            try {
                repository.save(Machine(UUID.randomUUID().toString(), name.trim(), requireNotNull(endpoint)))
                mutableState.update { it.copy(saving = false, adding = false) }
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
                    val stop = notReady || incompatible || !wasConnected || code in setOf("approval_required", "unauthorized", "forbidden", "not_found", "process_exited")
                    val message = if (notReady) R.string.terminal_not_ready else if (incompatible) R.string.incompatible_terminal else if (code == "approval_required") R.string.approval_required else if (stop) R.string.connection_error else R.string.connection_reconnecting
                    mutableState.update { it.copy(
                        connections = it.connections + (machine.id to (it.connections[machine.id] ?: Connection()).copy(checking = !stop, connected = false, error = message)),
                        terminalLoading = false, terminalError = if (target != null) message else it.terminalError,
                        terminalErrorDetail = if (target != null) detail else it.terminalErrorDetail,
                    ) }
                    if (stop) break
                    delay(minOf(1_000L shl retry.coerceAtMost(4), 15_000L))
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

    fun sendInput(text: String, onDelivered: (Boolean) -> Unit) {
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
                mutableState.update { it.copy(inputSending = false) }
                onDelivered(true)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                mutableState.update { it.copy(inputSending = false, error = R.string.input_failed) }
                onDelivered(false)
            }
        }
    }
}
