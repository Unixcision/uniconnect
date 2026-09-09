package com.unixcision.uniconnect.android.domain

/**
 * What the host says it has: its name, its workspaces, and the optional features it advertises.
 *
 * [capabilities] is the host's own list (`capabilities` in the workspace list); a host that keeps
 * favourites and order for its clients announces ``BOX_UPDATE`` there, one that takes files over
 * the private connection announces ``FILE_PUT``. Nothing is inferred from error codes: an absent
 * capability means the phone keeps those on its own or goes another way.
 */
data class MachineSnapshot(val serverName: String, val workspaces: List<RemoteWorkspace>, val capabilities: Set<String> = emptySet()) {
    val keepsBoxes: Boolean get() = BOX_UPDATE in capabilities

    /** Whether `mobile.file.begin/chunk/commit/abort` can be used against this host. */
    val putsFiles: Boolean get() = FILE_PUT in capabilities

    companion object {
        /** The host implements mobile.workspace.update and mobile.terminal.update. */
        const val BOX_UPDATE = "box_update"

        /** The host implements the file_put.v1 contract. */
        const val FILE_PUT = "file_put.v1"
    }
}
