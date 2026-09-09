package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.Machine

/**
 * The window an attachment is for, and whether its host takes files over the private connection.
 * Without [supportsFilePut] the attachment goes to the transfer service of "Enviar archivos" and
 * its link is pasted instead of a path.
 */
data class AttachTarget(val machine: Machine, val workspaceID: String, val windowID: String, val supportsFilePut: Boolean) {
    /** The same window, whichever snapshot it came from. */
    fun sameWindow(other: AttachTarget): Boolean = machine.id == other.machine.id && workspaceID == other.workspaceID && windowID == other.windowID
}
