package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.Machine

/**
 * The window an attachment is for: its machine, box and window, whether the box is an SSH one
 * (which decides whether a host-side copy is worth pasting), and whether the host takes files
 * over the private connection at all. Without [supportsFilePut] the sheet says so and only sends
 * the file to the transfer service of "Enviar archivos" on an explicit tap.
 */
data class AttachTarget(val machine: Machine, val workspaceID: String, val windowID: String, val isSSH: Boolean?, val supportsFilePut: Boolean) {
    /** The same window, whichever snapshot it came from. */
    fun sameWindow(other: AttachTarget): Boolean = machine.id == other.machine.id && workspaceID == other.workspaceID && windowID == other.windowID
}
