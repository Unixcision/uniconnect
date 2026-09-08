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
