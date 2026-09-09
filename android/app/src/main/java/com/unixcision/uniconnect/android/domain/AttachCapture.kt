package com.unixcision.uniconnect.android.domain

/**
 * What was captured when the reader tapped a picker button: the route the sheet announced and
 * the window it was for. It survives the picker taking over the screen, even across a process
 * death, as one line of restorable state; when the picker returns, the file goes only where this
 * says, or nowhere if the capture is gone or belongs to another window.
 */
data class AttachCapture(val route: AttachRoute, val machineID: String, val workspaceID: String, val windowID: String) {
    /** The one-line form kept in saved state. */
    fun encode(): String = listOf(route.name, machineID, workspaceID, windowID).joinToString(SEPARATOR)

    /** Whether the capture was made for this very window. */
    fun matches(machineID: String, workspaceID: String, windowID: String): Boolean =
        this.machineID == machineID && this.workspaceID == workspaceID && this.windowID == windowID

    companion object {
        private const val SEPARATOR = ""

        /**
         * What to do with a picker result that came back to the window [machineID] / [workspaceID] /
         * [windowID] with [saved] as the capture kept from the tap, when the host [takesFilesNow]
         * or not. Without a readable capture for this very window nothing is sent: the reader is
         * asked to pick again rather than have a destination rebuilt from newer values.
         */
        fun resolve(saved: String?, machineID: String, workspaceID: String, windowID: String, takesFilesNow: Boolean): AttachDecision {
            val capture = decode(saved) ?: return AttachDecision.PickAgain
            if (!capture.matches(machineID, workspaceID, windowID)) return AttachDecision.PickAgain
            return AttachDecision.onReturn(capture.route, takesFilesNow)
        }

        /** The capture behind [raw], or null when there is none or it cannot be read. */
        fun decode(raw: String?): AttachCapture? {
            val parts = raw?.split(SEPARATOR) ?: return null
            if (parts.size != 4 || parts.any { it.isEmpty() }) return null
            val route = AttachRoute.entries.firstOrNull { it.name == parts[0] } ?: return null
            return AttachCapture(route, parts[1], parts[2], parts[3])
        }
    }
}
