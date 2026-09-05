package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** Only authenticated server responses may become a MachineSnapshot. */
interface MachineClient {
    fun observe(machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate>
    suspend fun create(machine: Machine, request: ResourceCreation): CreationResult
    suspend fun inspect(machine: Machine): MachineSnapshot
    suspend fun replay(machine: Machine, workspaceID: String, windowID: String): TerminalSnapshot
    suspend fun sendInput(machine: Machine, workspaceID: String, windowID: String, text: String)
    /** Asks the desktop to reattach this window's durable session; never creates a new one. */
    suspend fun reconnect(machine: Machine, workspaceID: String, windowID: String)
    /** Scrolls the desktop viewport by whole lines; the phone never resizes the desktop terminal. */
    suspend fun scroll(machine: Machine, workspaceID: String, windowID: String, deltaLines: Int)
}
