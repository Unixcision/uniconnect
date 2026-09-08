package com.unixcision.uniconnect.android.domain

/**
 * The names behind a notice, so the alert can say which window wants attention.
 *
 * A notice carries only ids; the names come from the last inventory the phone saw of that machine,
 * which is why either may be missing when a window was created after the last look.
 */
data class NoticeNames(val workspace: String?, val window: String?) {
    val isEmpty: Boolean get() = workspace == null && window == null

    companion object {
        val NONE = NoticeNames(null, null)

        /** Resolves the ids of [notice] against the workspaces of one machine. */
        fun resolve(workspaces: List<RemoteWorkspace>, notice: RemoteNotice): NoticeNames {
            val workspace = workspaces.firstOrNull { it.id == notice.workspaceID } ?: return NONE
            val window = notice.windowID?.let { id -> workspace.windows.firstOrNull { it.id == id } }
            return NoticeNames(workspace.name.takeIf { it.isNotBlank() }, window?.name?.takeIf { it.isNotBlank() })
        }
    }
}
