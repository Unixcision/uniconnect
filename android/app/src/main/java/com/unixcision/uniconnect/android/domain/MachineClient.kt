package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** Only authenticated server responses may become a MachineSnapshot. */
interface MachineClient {
    fun observe(machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate>
    /** Pins or moves a workspace on the host; a host without this method rejects with method_not_found. */
    suspend fun updateWorkspace(machine: Machine, workspaceID: String, isPinned: Boolean?, position: Int?): MachineSnapshot
    /** Pins or moves a window inside its workspace on the host. */
    suspend fun updateWindow(machine: Machine, workspaceID: String, windowID: String, isPinned: Boolean?, position: Int?): MachineSnapshot
    suspend fun create(machine: Machine, request: ResourceCreation): CreationResult

    /**
     * Previsualiza un relanzado sin ejecutarlo (`relaunch.plan`).
     *
     * Devuelve lo que tocaría y lo que deja fuera con su motivo, más un vale con caducidad. Existe
     * para poder enseñar «esto toca 26 agentes» mientras todavía es una frase.
     */
    suspend fun relaunchPlan(machine: Machine, verb: RelaunchVerb, scope: RelaunchScope): RelaunchPlan

    /**
     * Ejecuta un plan (`relaunch.apply`). No espera a que termine: vuelve en cuanto el equipo lo
     * acepta, y el estado se sigue con [relaunchStatus].
     */
    suspend fun relaunchApply(machine: Machine, plan: RelaunchPlan): RelaunchOperation

    /** Consulta una operación por su identificador (`relaunch.status`). No caduca. */
    suspend fun relaunchStatus(machine: Machine, operationID: String): RelaunchOperation

    /**
     * Pide al equipo lo que sabe de una ventana (`mobile.terminal.details`, `window_details.v1`).
     *
     * Es solo lectura: el equipo no guarda ni lanza nada. Si no puede comprobar en vivo, contesta con
     * lo guardado. El cuerpo por defecto existe para que los clientes falsos de las pruebas no
     * tengan que implementarlo; solo se llama si el equipo anuncia la capacidad.
     */
    suspend fun windowDetails(machine: Machine, workspaceID: String, windowID: String): WindowDetails =
        throw UnsupportedOperationException("mobile.terminal.details")
    suspend fun inspect(machine: Machine): MachineSnapshot
    /** One-shot authorized check for the machine list; never creates or attaches anything. */
    suspend fun probe(machine: Machine): MachineSnapshot
    suspend fun replay(machine: Machine, workspaceID: String, windowID: String): TerminalSnapshot
    suspend fun sendInput(machine: Machine, workspaceID: String, windowID: String, text: String)
    /** Asks the desktop to reattach this window's durable session; never creates a new one. */
    suspend fun reconnect(machine: Machine, workspaceID: String, windowID: String)
    /** Scrolls the desktop viewport by whole lines; the phone never resizes the desktop terminal. */
    suspend fun scroll(machine: Machine, workspaceID: String, windowID: String, deltaLines: Int)
    /** Attaches a phone-sized tmux client to the window's session; raw bytes flow both ways. */
    suspend fun attach(machine: Machine, workspaceID: String, windowID: String, columns: Int, rows: Int): TerminalAttachment
}
