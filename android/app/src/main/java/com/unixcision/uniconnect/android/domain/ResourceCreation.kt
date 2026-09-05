package com.unixcision.uniconnect.android.domain

/** Explicit mutations only. Names and paths are data, never shell command fragments. */
sealed interface ResourceCreation {
    val name: String
    val directory: String?
    data class Workspace(override val name: String, override val directory: String?, val sourceWorkspaceID: String?) : ResourceCreation
    data class Terminal(val workspaceID: String, override val name: String, override val directory: String?, val tmuxSession: String?) : ResourceCreation

    fun isValid(): Boolean {
        if (name.trim() != name || name.length !in 1..80 || name.any { it.isISOControl() }) return false
        if (directory != null && (!directory!!.startsWith('/') || directory!!.toByteArray(Charsets.UTF_8).size > 4096 || directory!!.any { it.isISOControl() })) return false
        return when (this) {
            is Workspace -> if (sourceWorkspaceID == null) directory != null else sourceWorkspaceID.isNotBlank()
            is Terminal -> workspaceID.isNotBlank() && (tmuxSession == null || Regex("[a-z0-9_](?:[a-z0-9_-]{0,38}[a-z0-9_])?").matches(tmuxSession))
        }
    }
}
