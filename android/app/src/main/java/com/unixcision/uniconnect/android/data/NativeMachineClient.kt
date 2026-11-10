package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject

/** The host approves the observed peer IP. This client never sends SSH secrets or creates on attach. */
class NativeMachineClient(
    private val rpc: FramedRpcClient,
    /** Apunta cómo acaba cada intento, para poder contarlo después. Ver ``ConnectionDiary``. */
    private val diary: ConnectionDiary = ConnectionDiary(),
    /** Qué red hay en el instante del apunte. `null` = no se sabe, y entonces no se inventa. */
    private val networkNow: (() -> String?)? = null,
) : MachineClient {
    private val decoder = TerminalFrameDecoder()

    override fun observe(machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate> {
        // El instante de apertura se fija por cada recogida, no por cada llamada: un flujo frío se
        // recoge varias veces y compartir el reloj entre recogidas apuntaría duraciones inventadas.
        var abierto = 0L
        return flow {
            abierto = System.currentTimeMillis()
            rpc.open(machine.endpoint).use { session ->
                emitAll(observeSession(session, machine, terminal))
            }
        }.catch { failure ->
            // Este es el camino que se sufre **dentro** de un terminal: la pantalla se queda
            // muerta y el compositor se apaga. Antes no se apuntaba —solo el sondeo—, así que el
            // informe de diagnóstico llegaba vacío justo en el fallo que había que explicar.
            noteFailure("seguir", machine, abierto, failure)
            if (failure is org.json.JSONException || failure is IllegalArgumentException) throw MachineFailure.ProtocolMismatch()
            throw failure
        }.flowOn(Dispatchers.Default)
    }

    internal fun observeSession(session: FramedRpcSession, machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate> = flow {
            subscribe(session, terminal)
            val updateWorkspaces: suspend () -> Unit = {
                emit(MachineUpdate.Workspaces(decodeMachine(machine, session.call("mobile.workspace.list", JSONObject()).value.getJSONObject("result"))))
            }
            updateWorkspaces()
            var screen: TerminalSnapshot? = null
            var replayOrdinal = 0L
            if (terminal != null) {
                val replay = requestReplay(session, terminal, updateWorkspaces)
                screen = replay.snapshot
                replayOrdinal = replay.ordinal
                emit(MachineUpdate.Terminal(screen))
            }
            while (true) {
                val first = session.nextEventOrHeartbeat(15_000)
                val events = if (first == null) emptyList() else listOf(first) + session.drainQueuedEvents()
                // A bounded RPC heartbeat detects silent network loss even when the desktop is idle.
                if (first == null || events.any { it.value.optString("topic") == "workspace.updated" }) {
                    updateWorkspaces()
                }
                if (terminal == null) continue
                var needsReplay = false
                var requiredRevision: ULong? = null
                for (event in events) {
                    if (event.value.optString("topic") == "terminal.updated") {
                        // Linux invalidates globally. Reading the selected surface never creates or attaches a tmux.
                        val changedID = event.value.optJSONObject("payload")?.optString("surface_id").orEmpty()
                        if (changedID.isEmpty() || changedID.equals(terminal.windowID, ignoreCase = true)) needsReplay = true
                        continue
                    }
                    if (event.value.optString("topic") != "terminal.render_grid") continue
                    val payload = event.value.getJSONObject("payload")
                    val grid = payload.optJSONObject("render_grid") ?: payload
                    if (!grid.optString("surface_id").equals(terminal.windowID, ignoreCase = true)) continue
                    val frame = decoder.decode(grid, terminal.windowID)
                    // A revision supersedes response order: event 3 can precede the response for replay 2.
                    if (frame.snapshot.revision == null && event.ordinal <= replayOrdinal) continue
                    if (needsReplay && !frame.full) {
                        frame.snapshot.revision?.let { requiredRevision = maxOf(requiredRevision ?: it, it) }
                        continue
                    }
                    screen = try {
                        frame.applyingTo(screen).also { applied ->
                            // A rejected full frame cannot erase a newer delta's missing baseline.
                            if (frame.full && applied === frame.snapshot && applied.coversRevision(requiredRevision)) {
                                needsReplay = false
                                requiredRevision = null
                            }
                        }
                    } catch (_: TerminalFrame.FullReplayRequired) {
                        needsReplay = true
                        frame.snapshot.revision?.let { requiredRevision = maxOf(requiredRevision ?: it, it) }
                        screen
                    }
                }
                if (needsReplay) {
                    val replay = requestReplay(session, terminal, updateWorkspaces, minimumRevision = requiredRevision)
                    replayOrdinal = replay.ordinal
                    screen = TerminalFrame(replay.snapshot, true, emptySet()).applyingTo(screen)
                }
                if (events.isNotEmpty()) emit(MachineUpdate.Terminal(requireNotNull(screen)))
            }
    }

    override suspend fun inspect(machine: Machine): MachineSnapshot = decodeMachine(machine, call(machine, "mobile.workspace.list", JSONObject()))

    override suspend fun updateWorkspace(machine: Machine, workspaceID: String, isPinned: Boolean?, position: Int?): MachineSnapshot {
        val params = JSONObject().put("workspace_id", workspaceID)
        isPinned?.let { params.put("is_pinned", it) }; position?.let { params.put("position", it) }
        return decodeMachine(machine, call(machine, "mobile.workspace.update", params))
    }

    override suspend fun updateWindow(machine: Machine, workspaceID: String, windowID: String, isPinned: Boolean?, position: Int?): MachineSnapshot {
        val params = JSONObject().put("workspace_id", workspaceID).put("terminal_id", windowID)
        isPinned?.let { params.put("is_pinned", it) }; position?.let { params.put("position", it) }
        return decodeMachine(machine, call(machine, "mobile.terminal.update", params))
    }

    // Recorded like a connection attempt: a creation that fails used to leave no trace but a
    // generic message on screen, and nobody could tell what the host answered.
    override suspend fun create(machine: Machine, request: ResourceCreation): CreationResult = recording("crear", machine) {
        val params = creationParameters(request)
        val method = if (request is ResourceCreation.Workspace) "workspace.create" else "mobile.terminal.create"
        // The machine answers once the new tmux session is alive (Linux waits up to 25 s, a
        // window that switches user up to 30 s): 12 s gave up on creations that were working.
        val result = call(machine, method, params, deadlineMillis = CREATE_DEADLINE_MILLIS)
        val workspaceID = when (request) {
            is ResourceCreation.Workspace -> result.getString("created_workspace_id")
            is ResourceCreation.Terminal -> request.workspaceID
        }
        val windowID = if (request is ResourceCreation.Terminal) result.getString("created_terminal_id") else null
        CreationResult(decodeMachine(machine, result), workspaceID, windowID)
    }

    override suspend fun closeWorkspace(machine: Machine, workspaceID: String): MachineSnapshot = recording("cerrar", machine) {
        val (method, params) = closeRequest(workspaceID, terminalID = null)
        decodeClosed(machine, call(machine, method, params), "closed_workspace_id", workspaceID)
    }

    override suspend fun closeTerminal(machine: Machine, workspaceID: String, terminalID: String): MachineSnapshot = recording("cerrar", machine) {
        val (method, params) = closeRequest(workspaceID, terminalID)
        decodeClosed(machine, call(machine, method, params), "closed_terminal_id", terminalID)
    }

    /**
     * The method and parameters that close a workspace, or one of its windows when [terminalID] is
     * given (`box-close.v1`). Only the ids travel: the host closes them exactly as its desktop would.
     */
    internal fun closeRequest(workspaceID: String, terminalID: String?): Pair<String, JSONObject> {
        require(workspaceID.isNotBlank() && terminalID?.isNotBlank() != false)
        val params = JSONObject().put("workspace_id", workspaceID)
        if (terminalID == null) return "workspace.close" to params
        return "terminal.close" to params.put("terminal_id", terminalID)
    }

    /**
     * Reads a close answer: the whole list, drawn as it comes. When the host names what it closed,
     * it has to be what was asked; the Mac sends its UUIDs in capitals.
     */
    internal fun decodeClosed(machine: Machine, result: JSONObject, closedKey: String, expectedID: String): MachineSnapshot {
        result.text(closedKey)?.let { closed -> require(closed.equals(expectedID, ignoreCase = true)) }
        return decodeMachine(machine, result)
    }

    override suspend fun relaunchPlan(machine: Machine, verb: RelaunchVerb, scope: RelaunchScope, options: RelaunchOptions?): RelaunchPlan =
        decodePlan(call(machine, "relaunch.plan", planParameters(verb, scope, options)), verb)

    /**
     * Los parámetros de `relaunch.plan`: verbo, alcance y, solo con `agent.update` y si se pide algún
     * cambio, `options`. Una clave que falta es «igual que estaba».
     */
    internal fun planParameters(verb: RelaunchVerb, scope: RelaunchScope, options: RelaunchOptions?): JSONObject {
        val params = JSONObject().put("verb", verb.wire).put("scope", scopeParameters(scope))
        if (options == null || options.isEmpty) return params
        // Relanzar no cambia nada: el equipo contestaría opciones_no_validas.
        require(verb == RelaunchVerb.UPDATE) { "agent.relaunch no lleva opciones" }
        require(options.isValid) { "opciones fuera del contrato" }
        val wire = JSONObject()
        options.model?.let { wire.put("model", it) }
        options.effort?.let { wire.put("effort", it) }
        return params.put("options", wire)
    }

    override suspend fun relaunchApply(machine: Machine, plan: RelaunchPlan): RelaunchOperation {
        val params = JSONObject().put("operation_id", plan.operationID).put("token", plan.token)
        return decodeOperation(call(machine, "relaunch.apply", params))
    }

    override suspend fun relaunchStatus(machine: Machine, operationID: String): RelaunchOperation =
        decodeOperation(call(machine, "relaunch.status", JSONObject().put("operation_id", operationID)))

    override suspend fun windowDetails(machine: Machine, workspaceID: String, windowID: String): WindowDetails {
        val params = JSONObject().put("workspace_id", workspaceID).put("terminal_id", windowID)
        val details = decodeDetails(call(machine, "mobile.terminal.details", params))
        // La respuesta tiene que ser de la ventana que se pidió. El Mac manda los UUID en mayúsculas.
        require(details.windowID.isEmpty() || details.windowID.equals(windowID, ignoreCase = true))
        return details
    }

    override suspend fun accounts(machine: Machine): AccountsReport {
        // `{}`: todas las ventanas de todos los espacios. El equipo tarda como mucho 12 s con todas
        // sus sondas en paralelo; 15 s deja margen a la red sin esperar para siempre.
        val result = call(machine, "mobile.accounts.list", JSONObject(), ACCOUNTS_DEADLINE_MILLIS)
        return try {
            decodeAccounts(result)
        } catch (malformed: org.json.JSONException) {
            throw MachineFailure.ProtocolMismatch()
        }
    }

    override suspend fun codexReset(machine: Machine, accountKey: String, hostKey: String, idempotencyKey: String): CodexResetResult {
        val result = call(machine, "mobile.accounts.codex_reset", codexResetParameters(accountKey, hostKey, idempotencyKey), CODEX_RESET_DEADLINE_MILLIS)
        return try {
            decodeCodexReset(result)
        } catch (malformed: org.json.JSONException) {
            throw MachineFailure.ProtocolMismatch()
        }
    }

    /** Los parámetros de §5: la cuenta, el host donde se vio su uso y la clave de esa confirmación. */
    internal fun codexResetParameters(accountKey: String, hostKey: String, idempotencyKey: String): JSONObject {
        require(accountKey.isNotBlank() && hostKey.isNotBlank() && idempotencyKey.isNotBlank())
        return JSONObject().put("account_key", accountKey).put("host_key", hostKey).put("idempotency_key", idempotencyKey)
    }

    /** La respuesta de `mobile.accounts.codex_reset`: `{account_key, host_key, outcome, usage}`. */
    internal fun decodeCodexReset(result: JSONObject): CodexResetResult = CodexResetResult(
        accountKey = result.text("account_key").orEmpty(),
        hostKey = result.text("host_key").orEmpty(),
        outcomeWire = result.text("outcome").orEmpty(),
        usage = result.optJSONObject("usage")?.let(::decodeUsage),
    )

    /**
     * Lee una respuesta de `accounts.v1`.
     *
     * Los `null` del contrato se miran con `isNull`, como en los Detalles: un `null` de JSON leído
     * con `optString` es el texto «null», y una cuenta llamada así es peor que ninguna.
     */
    internal fun decodeAccounts(result: JSONObject): AccountsReport {
        val hosts = result.optJSONArray("hosts") ?: JSONArray()
        val windows = result.optJSONArray("windows") ?: JSONArray()
        return AccountsReport(
            version = result.optInt("version", 1),
            checkedAt = result.text("checked_at"),
            hosts = List(hosts.length()) { index ->
                val host = hosts.getJSONObject(index)
                AccountHost(
                    hostKey = host.getString("host_key"),
                    label = host.text("label").orEmpty(),
                    kind = host.text("kind") ?: "local",
                    state = host.text("state") ?: AccountHost.UNREACHABLE,
                    checkedAt = host.text("checked_at"),
                    error = host.text("error"),
                    errorDetail = host.text("error_detail"),
                )
            },
            windows = List(windows.length()) { index ->
                val window = windows.getJSONObject(index)
                AccountWindow(
                    workspaceID = window.getString("workspace_id"),
                    workspace = window.text("workspace").orEmpty(),
                    terminalID = window.getString("terminal_id"),
                    window = window.text("window").orEmpty(),
                    hostKey = window.text("host_key") ?: "local",
                    tmuxSession = window.text("tmux_session"),
                    // Sin estado no se da por leída: se cuenta como «sin leer».
                    stateWire = window.text("state") ?: "",
                    agent = window.optJSONObject("agent")?.let { agent ->
                        val provider = agent.text("provider").orEmpty()
                        AccountAgent(provider, agent.text("display_name") ?: provider, agent.flag("as_root"))
                    },
                    account = window.optJSONObject("account")?.let { account ->
                        AccountInfo(
                            email = account.text("email"),
                            method = account.text("method"),
                            plan = account.text("plan"),
                            organization = account.text("organization"),
                            osUser = account.text("os_user"),
                            config = account.text("config"),
                            readAt = account.text("read_at"),
                            usage = account.optJSONObject("usage")?.let(::decodeUsage),
                        )
                    },
                )
            },
            accounts = result.optJSONArray("accounts")?.objects().orEmpty().map { account ->
                val hostKeys = account.optJSONArray("host_keys") ?: JSONArray()
                val history = account.optJSONArray("history") ?: JSONArray()
                AccountSummary(
                    key = account.getString("key"),
                    provider = account.text("provider").orEmpty(),
                    displayName = account.text("display_name") ?: account.text("provider").orEmpty(),
                    email = account.text("email"),
                    plan = account.text("plan"),
                    organization = account.text("organization"),
                    windows = account.optInt("windows", 0),
                    hostKeys = List(hostKeys.length()) { hostKeys.optString(it) }.filter { it.isNotEmpty() },
                    usage = account.optJSONObject("usage")?.let(::decodeUsage),
                    // Una muestra sin fecha no se puede poner en la gráfica: se deja fuera.
                    history = history.objects().mapNotNull { sample ->
                        val at = sample.instant("at") ?: return@mapNotNull null
                        val limits = sample.optJSONObject("limits") ?: JSONObject()
                        UsageSample(at, limits.keys().asSequence().mapNotNull { id -> limits.number(id)?.let { id to it } }.toMap())
                    }.sortedBy { it.at },
                )
            },
        )
    }

    /** Un `usage` de §2.4. Un límite sin porcentaje no se inventa: se deja fuera. */
    private fun decodeUsage(usage: JSONObject): AccountUsage = AccountUsage(
        source = usage.text("source"),
        observedAt = usage.instant("observed_at"),
        limits = usage.optJSONArray("limits")?.objects().orEmpty().mapNotNull { limit ->
            val id = limit.text("id") ?: return@mapNotNull null
            val percent = limit.number("used_percent") ?: return@mapNotNull null
            UsageLimit(id, percent, limit.instant("resets_at"), limit.whole("window_minutes")?.toInt())
        },
        hostKey = usage.text("host_key"),
        resetCredits = usage.optJSONObject("reset_credits")?.let { credits ->
            ResetCredits(credits.whole("available")?.toInt() ?: 0, credits.instant("next_expires_at"))
        },
    )

    /** Un instante ISO 8601 de [key], o nulo si falta, es `null` o no se entiende. */
    private fun JSONObject.instant(key: String): java.time.Instant? =
        text(key)?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }

    /** Un número (entero o decimal) de [key], o nulo si falta o no es un número. */
    private fun JSONObject.number(key: String): Double? =
        if (!has(key) || isNull(key)) null else (opt(key) as? Number)?.toDouble()

    /**
     * Lee una respuesta de `window_details.v1`.
     *
     * Los `null` del contrato se miran con `isNull`: en Android, `optString` de un `null` de JSON
     * devuelve el texto `"null"`, y una carpeta llamada «null» es peor que ninguna.
     */
    internal fun decodeDetails(result: JSONObject): WindowDetails {
        val workspace = result.optJSONObject("workspace") ?: JSONObject()
        val tmux = result.optJSONObject("tmux")
        val agent = result.optJSONObject("agent")
        return WindowDetails(
            workspaceID = result.text("workspace_id").orEmpty(),
            windowID = result.text("terminal_id").orEmpty(),
            checkedAt = result.text("checked_at"),
            workspaceName = workspace.text("name").orEmpty(),
            workspaceKind = workspace.text("kind") ?: "local",
            host = workspace.optJSONObject("host")?.let { host ->
                host.text("hostname")?.let { hostname ->
                    DetailsHost(host.text("user"), hostname, if (host.has("port") && !host.isNull("port")) host.optInt("port") else null)
                }
            },
            hostLabel = workspace.text("host_label"),
            windowName = result.optJSONObject("window")?.text("name").orEmpty(),
            tmux = tmux?.let {
                DetailsTmux(
                    socket = it.text("socket") ?: "default",
                    session = it.text("session").orEmpty(),
                    sessionID = it.text("session_id"),
                    paneID = it.text("pane_id"),
                    live = it.optBoolean("live", false),
                )
            },
            agent = agent?.let {
                DetailsAgent(
                    provider = it.text("provider").orEmpty(),
                    displayName = it.text("display_name"),
                    sessionID = it.text("session_id"),
                    cwd = it.text("cwd"),
                    asRoot = if (it.has("as_root") && !it.isNull("as_root")) it.optBoolean("as_root") else null,
                    source = it.text("source"),
                    state = it.text("state"),
                    observedAt = it.text("observed_at"),
                    resume = it.optJSONObject("resume")?.let { resume ->
                        val argv = resume.optJSONArray("argv") ?: JSONArray()
                        val environment = resume.optJSONObject("environment") ?: JSONObject()
                        DetailsResume(
                            argv = List(argv.length()) { index -> argv.optString(index) },
                            environment = environment.keys().asSequence().associateWith { key -> environment.optString(key) },
                            command = resume.text("command").orEmpty(),
                            noPromptVerified = resume.optBoolean("no_prompt_verified", false),
                        )
                    }?.takeIf { resume -> resume.command.isNotEmpty() },
                )
            },
            reason = result.text("reason"),
        )
    }

    /** El texto de [key], o nulo si falta, es `null` o está vacío. */
    private fun JSONObject.text(key: String): String? =
        if (!has(key) || isNull(key)) null else optString(key).takeIf { it.isNotEmpty() }

    /** El número entero de [key], o nulo si falta, es `null` o no es un número. Nunca un cero inventado. */
    private fun JSONObject.whole(key: String): Long? =
        if (!has(key) || isNull(key)) null else (opt(key) as? Number)?.toLong()

    /** El booleano de [key], o nulo si falta, es `null` o no es un booleano: «no lo dice» no es «no». */
    private fun JSONObject.flag(key: String): Boolean? =
        if (!has(key) || isNull(key)) null else opt(key) as? Boolean

    /** Los textos de la lista [key], vacía si falta. */
    private fun JSONObject.texts(key: String): List<String> {
        val items = optJSONArray(key) ?: return emptyList()
        return List(items.length()) { index -> items.optString(index) }.filter { it.isNotEmpty() }
    }

    /**
     * Segundos desde época en [key], o nulo si falta, es `null` o no es un instante. Se mira con
     * `isNull`: un `null` de JSON no es un cero, y un cero pintaría «Hace 56 años».
     */
    private fun JSONObject.epochSeconds(key: String): Long? =
        if (!has(key) || isNull(key)) null else optLong(key, 0L).takeIf { it > 0L }

    internal fun scopeParameters(scope: RelaunchScope): JSONObject = when (scope) {
        // Solo `kind` e `id` viajan. El espacio al que pertenece una ventana se queda en el modelo
        // y en la pantalla: mandarlo invitaría a que el equipo decidiera con él, y quien resuelve
        // un objetivo es el que lo tiene delante.
        is RelaunchScope.Window -> JSONObject().put("kind", "window").put("id", scope.windowID)
        is RelaunchScope.Workspace -> JSONObject().put("kind", "workspace").put("id", scope.workspaceID)
        is RelaunchScope.Machine -> JSONObject().put("kind", "machine").put("id", scope.machineID)
    }

    internal fun decodePlan(result: JSONObject, verb: RelaunchVerb): RelaunchPlan {
        val targets = result.optJSONArray("targets") ?: JSONArray()
        val excluded = result.optJSONArray("excluded") ?: JSONArray()
        return RelaunchPlan(
            operationID = result.getString("operation_id"),
            token = result.getString("token"),
            verb = verb,
            targets = List(targets.length()) { index ->
                val item = targets.getJSONObject(index)
                RelaunchTarget(
                    item.getString("key"), item.optString("label"), item.optString("provider"),
                    warning = item.text("warning")?.let(::RelaunchReason),
                    // Desde el 09-11-2026. Un equipo anterior no los manda y se quedan en nulo.
                    background = item.whole("background")?.toInt(),
                    draft = item.flag("draft"),
                    contextTokens = item.whole("context_tokens"),
                    message = item.flag("message"),
                    version = item.text("version"),
                    installed = item.text("installed"),
                )
            },
            // Una exclusión sin motivo se lee como una ventana olvidada, así que el motivo viaja
            // siempre aunque esta versión no sepa nombrarlo.
            exclusions = List(excluded.length()) { index ->
                val item = excluded.getJSONObject(index)
                RelaunchExclusion(item.optString("label"), RelaunchReason.of(item.optString("cause")))
            },
            // El equipo puede decir que todavía no puede relanzar; si lo dice, se enseña antes de
            // que nadie pulse nada.
            unavailableReason = result.text("unavailable_reason"),
            options = result.optJSONObject("options")?.let { RelaunchOptions(it.text("model"), it.text("effort")) } ?: RelaunchOptions(),
            estimatedTokens = result.whole("estimated_tokens"),
        )
    }

    internal fun decodeOperation(result: JSONObject): RelaunchOperation {
        val results = result.optJSONArray("results") ?: JSONArray()
        val updates = result.optJSONArray("updates") ?: JSONArray()
        return RelaunchOperation(
            operationID = result.getString("operation_id"),
            recovered = result.optBoolean("recovered", false),
            results = List(results.length()) { index ->
                val item = results.getJSONObject(index)
                RelaunchResult(
                    key = item.getString("key"),
                    state = RelaunchTargetState.named(item.optString("state")),
                    reason = RelaunchReason.of(item.optString("cause")),
                    effectiveID = item.text("effective_id"),
                    escalation = item.text("escalation"),
                    droppedOptions = item.texts("dropped_options"),
                    version = item.text("version"),
                    model = item.text("model"),
                    effort = item.text("effort"),
                    backgroundSaved = item.whole("background_saved")?.toInt(),
                    messageSent = item.flag("message_sent"),
                    draftRestored = item.flag("draft_restored"),
                )
            },
            // Lo que dice si terminó. Un equipo que no lo manda (el `apply` bloqueante del Mac
            // antiguo) deja que decidan los objetivos.
            operationState = result.text("operation_state"),
            updates = List(updates.length()) { index ->
                val item = updates.getJSONObject(index)
                RelaunchUpdate(item.text("host").orEmpty(), item.optString("state"), item.text("from"), item.text("to"))
            },
        )
    }

    internal fun creationParameters(request: ResourceCreation): JSONObject {
        require(request.isValid())
        val params = JSONObject().put("name", request.name)
        request.directory?.let { params.put("directory", it) }
        when (request) {
            is ResourceCreation.Workspace -> {
                val ssh = request.sourceWorkspaceID != null || request.connectCommand != null
                params.put("kind", if (ssh) "ssh" else "local")
                request.sourceWorkspaceID?.let { params.put("source_workspace_id", it) }
                // ssh_create.v1. The command may carry a password, so it is never logged here and
                // never stored on the phone; the machine validates it and keeps it in its vault.
                request.connectCommand?.let { params.put("connect_command", it) }
                // Older hosts ignore the flag and still open one terminal; the reconciled tree tells us.
                if (!request.initialTerminal) params.put("initial_terminal", false)
                // Who runs it only matters when the host opens that first window here.
                if (request.initialTerminal) putRunAs(params, request.runAs, RunAs.sandboxFor(request.runAs, null, request.isSandbox))
            }
            is ResourceCreation.Terminal -> {
                params.put("workspace_id", request.workspaceID)
                params.put("agent", request.agentID)
                request.tmuxSession?.let { params.put("tmux_session", it) }
                putRunAs(params, request.runAs, RunAs.sandboxFor(request.runAs, request.agentID, request.isSandbox))
            }
        }
        return params
    }

    /**
     * Adds `run_as` and `is_sandbox` (`run-as.v1`). The connected user travels as nothing, as before
     * the contract, so an older host sees the request it always saw. The password goes only when
     * typed; it is never logged or stored on the phone, and the host keeps it in its vault.
     */
    private fun putRunAs(params: JSONObject, runAs: RunAs?, sandbox: Boolean) {
        if (runAs != null && runAs.switchesUser) {
            val switch = JSONObject().put("mode", runAs.mode.wire).put("method", runAs.method.wire)
            if (runAs.mode == RunAs.Mode.USER) switch.put("user", runAs.user)
            runAs.password?.takeIf { it.isNotEmpty() }?.let { switch.put("password", it) }
            params.put("run_as", switch).put("is_sandbox", sandbox)
        } else if (sandbox) {
            params.put("is_sandbox", true)
        }
    }

    override suspend fun replay(machine: Machine, workspaceID: String, windowID: String): TerminalSnapshot =
        rpc.open(machine.endpoint).use { session ->
            val terminal = TerminalTarget(workspaceID, windowID)
            subscribe(session, terminal)
            requestReplay(session, terminal).snapshot
        }

    override suspend fun sendInput(machine: Machine, workspaceID: String, windowID: String, text: String) {
        require(text.isNotEmpty())
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_INPUT_BYTES)
        val result = call(machine, "mobile.terminal.input", target(workspaceID, windowID).put("text", text))
        val actual = TerminalTarget(result.getString("workspace_id"), result.getString("surface_id"))
        if (!TerminalInputReceipt.accepts(TerminalTarget(workspaceID, windowID), actual, result.opt("queued") as? Boolean)) throw MachineFailure.InputNotQueued()
    }

    override suspend fun reconnect(machine: Machine, workspaceID: String, windowID: String) = recording("reconectar", machine) {
        val result = call(machine, "mobile.terminal.reconnect", target(workspaceID, windowID))
        val actual = TerminalTarget(result.getString("workspace_id"), result.getString("surface_id"))
        if (!TerminalInputReceipt.accepts(TerminalTarget(workspaceID, windowID), actual, result.opt("queued") as? Boolean)) throw MachineFailure.InputNotQueued()
    }

    override suspend fun scroll(machine: Machine, workspaceID: String, windowID: String, deltaLines: Int) {
        require(deltaLines != 0 && deltaLines in -1000..1000)
        // macOS reads delta_lines; Linux reads lines. Both identify the same explicit surface.
        val params = target(workspaceID, windowID).put("delta_lines", deltaLines).put("lines", deltaLines)
        val result = call(machine, "mobile.terminal.scroll", params)
        require(result.getString("surface_id").equals(windowID, ignoreCase = true))
    }

    /**
     * Ejecuta un intento y deja constancia de cómo acabó.
     *
     * El sondeo es el que decide si una máquina cuenta como conectada, así que es el que hay que
     * poder explicar: sin esto, un fallo aquí se manifestaba como «no conectado» en toda la app y
     * no quedaba rastro de si fue un rechazo, un plazo agotado o un socket que no llegó a abrirse.
     */
    private suspend fun <T> recording(stage: String, machine: Machine, block: suspend () -> T): T {
        val started = System.currentTimeMillis()
        return try {
            block().also { note(stage, machine, started, ConnectionEvent.Outcome.OK, null) }
        } catch (cancelled: CancellationException) {
            note(stage, machine, started, ConnectionEvent.Outcome.CANCELADO, null); throw cancelled
        } catch (failure: Throwable) {
            noteFailure(stage, machine, started, failure); throw failure
        }
    }

    /** Apunta un desenlace concreto. Nunca deduce nada que no haya pasado de verdad. */
    private fun note(stage: String, machine: Machine, started: Long, outcome: ConnectionEvent.Outcome, detail: String?) =
        diary.record(
            ConnectionEvent(
                at = started, stage = stage, machine = machine.name,
                endpoint = "${machine.endpoint.host}:${machine.endpoint.port}",
                outcome = outcome, millis = System.currentTimeMillis() - started, detail = detail,
                network = runCatching { networkNow?.invoke() }.getOrNull(),
            )
        )

    /**
     * Traduce un fallo a un apunte, conservando el dato que lo distingue de los demás.
     *
     * Separado de ``recording`` porque los caminos largos —seguir un terminal— no caben en un
     * bloque con principio y final: fallan a mitad del flujo, y ahí solo hay un fallo que apuntar.
     */
    private fun noteFailure(stage: String, machine: Machine, started: Long, failure: Throwable) {
        if (failure is CancellationException) { note(stage, machine, started, ConnectionEvent.Outcome.CANCELADO, null); return }
        note(
            stage, machine, started,
            when (failure) {
                is MachineFailure.DeadlineExceeded -> ConnectionEvent.Outcome.PLAZO_AGOTADO
                is MachineFailure.Rejected -> ConnectionEvent.Outcome.RECHAZADO
                else -> ConnectionEvent.Outcome.ERROR_TRANSPORTE
            },
            when (failure) {
                is MachineFailure.Rejected -> failure.code + (failure.detail?.let { ": $it" }.orEmpty())
                // El nombre de la excepción es el dato: distingue un socket rechazado de uno
                // que nunca llegó a abrirse.
                else -> failure::class.java.simpleName +
                    (failure.message?.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty())
            },
        )
    }

    /** Todo lo apuntado, para el informe de diagnóstico. */
    fun connectionHistory(): List<ConnectionEvent> = diary.all()

    /** Si conviene ofrecer el diagnóstico sin que lo pidan. */
    fun troubled(): Boolean = diary.worthReporting()

    override suspend fun probe(machine: Machine): MachineSnapshot =
        // Tiene que ser mayor que lo que tarda **abrir**: `open` se permite 15 s y el socket 7 s
        // para el apretón de manos. Con 6 s aquí, el sondeo se rendía antes de que la conexión
        // llegara a existir — en wifi no se nota porque abre en milisegundos, y por datos móviles,
        // donde Tailscale puede tirar por relé, fallaba **siempre**. Después la máquina quedaba
        // marcada como desconectada y todo lo demás fallaba sin decir por qué, incluido el bucle
        // de reintentos que repetía el mismo plazo imposible.
        //
        // La lista no se resiente: los sondeos salen en paralelo (uno por máquina), así que una
        // que esté apagada ya no retrasa a las demás por mucho que agote su plazo.
        recording("sondeo", machine) { transportDeadline(20_000) {
            rpc.open(machine.endpoint).use { session ->
                decodeMachine(machine, session.call("mobile.workspace.list", JSONObject()).value.getJSONObject("result"))
            }
        } }

    override suspend fun attach(machine: Machine, workspaceID: String, windowID: String, columns: Int, rows: Int): TerminalAttachment =
        recording("adjuntar", machine) {
            NativeTerminalAttachment.open(rpc.open(machine.endpoint), workspaceID, windowID, columns.coerceIn(1, 1000), rows.coerceIn(1, 1000))
        }

    private fun decodeActivity(json: JSONObject?): RemoteActivity? = json?.let {
        // A JSON null is not the text "null": hosts send `"agent": null` for a window with no AI.
        RemoteActivity(ActivityState.parse(it.optString("state", "")), it.text("source"), it.text("agent"),
            if (it.has("since") && !it.isNull("since")) it.optLong("since") else null)
    }

    private fun decodeMachine(machine: Machine, result: JSONObject): MachineSnapshot {
        val workspaces = result.getJSONArray("workspaces").objects().map { workspace ->
            val terminals = workspace.getJSONArray("terminals").objects().map { terminal ->
                RemoteWindow(terminal.getString("id"), terminal.getString("title"), "terminal", terminal.optBoolean("is_pinned", false), decodeActivity(terminal.optJSONObject("activity")),
                    lastPromptAt = terminal.epochSeconds("last_prompt_at"))
            }
            require(terminals.map { it.id }.distinct().size == terminals.size)
            val kind = when (workspace.optString("kind")) { "ssh" -> true; "local" -> false; else -> null }
            val targets = (workspace.optJSONArray("available_agent_targets") ?: JSONArray()).objects().map {
                RemoteAgentTarget(it.getString("id"), it.getString("title"))
            }
            require(targets.map { it.id }.distinct().size == targets.size)
            RemoteWorkspace(workspace.getString("id"), workspace.getString("title"), kind, terminals, targets, workspace.optBoolean("is_pinned", false),
                workspace.optJSONObject("activity")?.let { ActivityState.parse(it.optString("state", "")) })
        }
        require(workspaces.map { it.id }.distinct().size == workspaces.size)
        val capabilities = (result.optJSONArray("capabilities") ?: JSONArray()).let { array -> List(array.length()) { array.optString(it) } }.filter { it.isNotEmpty() }.toSet()
        return MachineSnapshot(result.optString("display_name", machine.name), workspaces, capabilities)
    }

    private fun decodeReplay(result: JSONObject, windowID: String): TerminalSnapshot? {
        require(result.getString("surface_id").equals(windowID, ignoreCase = true))
        if (result.opt("is_ready") == false) return null
        val frame = decoder.decode(result.optJSONObject("render_grid") ?: throw MachineFailure.UnsupportedTerminal(), windowID)
        if (!frame.full) throw MachineFailure.UnsupportedTerminal()
        return frame.snapshot
    }

    private suspend fun subscribe(session: FramedRpcSession, terminal: TerminalTarget?) {
        val streamID = UUID.randomUUID().toString()
        val topics = JSONArray().put("workspace.updated")
        val params = JSONObject().put("stream_id", streamID).put("topics", topics)
        if (terminal != null) {
            topics.put("terminal.render_grid").put("terminal.updated")
            // Only this window's screen. Without it the Mac sent the full screen of every busy
            // window, the connection's queue overflowed and the mirror died in half a second.
            params.put("surface_ids", JSONArray().put(terminal.windowID))
        }
        val subscribed = session.call("mobile.events.subscribe", params)
        require(subscribed.value.getJSONObject("result").getString("stream_id") == streamID)
    }

    /** Cold surfaces complete through their existing subscription, never another create/attach or replay poll. */
    internal suspend fun requestReplay(
        session: FramedRpcSession,
        terminal: TerminalTarget,
        updateWorkspaces: suspend () -> Unit = {},
        minimumRevision: ULong? = null,
    ): ReplayScreen {
        var waitingForSurface = false
        var requiredRevision = minimumRevision
        return try {
            transportDeadline(12_000) {
                val reply = session.call("mobile.terminal.replay", target(terminal.workspaceID, terminal.windowID))
                val result = reply.value.getJSONObject("result")
                require(result.getString("workspace_id").equals(terminal.workspaceID, ignoreCase = true))
                decodeReplay(result, terminal.windowID)?.takeIf { it.coversRevision(requiredRevision) }
                    ?.let { return@transportDeadline ReplayScreen(it, reply.ordinal) }
                waitingForSurface = true
                var ready: ReplayScreen? = null
                while (ready == null) {
                    val event = session.nextEventOrHeartbeat(12_000) ?: throw MachineFailure.DeadlineExceeded()
                    when (event.value.optString("topic")) {
                        "workspace.updated" -> updateWorkspaces()
                        "terminal.render_grid" -> {
                            val payload = event.value.getJSONObject("payload")
                            val grid = payload.optJSONObject("render_grid") ?: payload
                            if (!grid.optString("surface_id").equals(terminal.windowID, ignoreCase = true)) continue
                            val frame = decoder.decode(grid, terminal.windowID)
                            if (!frame.full) {
                                frame.snapshot.revision?.let { requiredRevision = maxOf(requiredRevision ?: it, it) }
                            } else if (frame.snapshot.coversRevision(requiredRevision)) {
                                ready = ReplayScreen(frame.snapshot, event.ordinal)
                            }
                        }
                    }
                }
                ready
            }
        } catch (failure: MachineFailure.DeadlineExceeded) {
            if (waitingForSurface) throw MachineFailure.TerminalNotReady()
            throw failure
        }
    }

    internal data class ReplayScreen(val snapshot: TerminalSnapshot, val ordinal: Long)

    private fun TerminalSnapshot.coversRevision(minimum: ULong?): Boolean =
        minimum == null || (revision != null && revision >= minimum)

    private suspend fun call(machine: Machine, method: String, params: JSONObject, deadlineMillis: Long = 12_000): JSONObject =
        rpc.call(machine.endpoint, method, params, deadlineMillis).getJSONObject("result")
    private fun target(workspaceID: String, windowID: String) = JSONObject().put("workspace_id", workspaceID).put("surface_id", windowID)
    private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
    companion object {
        const val MAX_INPUT_BYTES = 256 * 1024
        /** How long a creation may take before the phone stops waiting for the answer. */
        const val CREATE_DEADLINE_MILLIS = 45_000L
        /** How long «Cuentas de IA» waits for one machine: its probes take up to 12 s (accounts.v1). */
        const val ACCOUNTS_DEADLINE_MILLIS = 15_000L
        /** How long a free Codex reset may take: the host's probe waits up to 8 s for Codex (§5). */
        const val CODEX_RESET_DEADLINE_MILLIS = 20_000L
    }
}
