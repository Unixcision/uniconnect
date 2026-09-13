package com.unixcision.uniconnect.android.domain

/** Explicit mutations only. Names and paths are data, never shell command fragments. */
sealed interface ResourceCreation {
    val name: String
    val directory: String?
    /** [initialTerminal] false asks the host not to spawn a plain terminal, so the first window is chosen explicitly. */
    /**
     * A new box. Exactly one of three shapes: a local folder, an SSH box that reuses the
     * credential of [sourceWorkspaceID], or an SSH box whose [connectCommand] the reader typed
     * here.
     *
     * A typed command may carry a password. It travels inside the private tunnel to the machine,
     * which validates it with the same parser its own desktop form uses and keeps it in its
     * encrypted vault; the phone never writes it to disk and never gets it back.
     */
    data class Workspace(
        override val name: String,
        override val directory: String?,
        val sourceWorkspaceID: String?,
        val initialTerminal: Boolean = true,
        val connectCommand: String? = null,
    ) : ResourceCreation
    data class Terminal(
        val workspaceID: String,
        override val name: String,
        override val directory: String?,
        val tmuxSession: String?,
        val agentID: String = "terminal",
    ) : ResourceCreation {
        fun isAllowedIn(workspace: RemoteWorkspace): Boolean = isValid() && workspace.id == workspaceID &&
            workspace.isSSH != null && workspace.isSSH == (tmuxSession != null) &&
            workspace.availableAgentTargets.any { it.id == agentID }
    }

    /**
     * Whether [command] is worth sending at all. The machine is the one that decides if a command
     * is safe — it owns the parser and the vault — so this only rejects what could never be one:
     * empty, enormous, or carrying control characters that would split it into two commands.
     */
    fun isUsableConnectCommand(command: String): Boolean =
        command.trim() == command && command.isNotEmpty() &&
            command.toByteArray(Charsets.UTF_8).size <= MAX_CONNECT_COMMAND_BYTES &&
            command.none { it.isISOControl() }

    fun isValid(): Boolean {
        if (name.trim() != name || name.length !in 1..80 || name.any { it.isISOControl() }) return false
        if (directory != null && (!directory!!.startsWith('/') || directory!!.toByteArray(Charsets.UTF_8).size > 4096 || directory!!.any { it.isISOControl() })) return false
        return when (this) {
            is Workspace -> when {
                connectCommand != null -> sourceWorkspaceID == null && directory == null && isUsableConnectCommand(connectCommand)
                sourceWorkspaceID != null -> sourceWorkspaceID.isNotBlank()
                else -> directory != null
            }
            is Terminal -> workspaceID.isNotBlank() && agentID.isNotBlank() && agentID.trim() == agentID &&
                agentID.toByteArray(Charsets.UTF_8).size <= 128 && agentID.none { it.isISOControl() } &&
                (tmuxSession == null || (agentID == "terminal" && Regex("[a-z0-9_](?:[a-z0-9_-]{0,38}[a-z0-9_])?").matches(tmuxSession)))
        }
    }

    companion object {
        /** Matches the machines' own cap, so an oversized command is refused before it travels. */
        const val MAX_CONNECT_COMMAND_BYTES = 4096
    }
}
