package com.unixcision.uniconnect.android.domain

/** Explicit mutations only. Names and paths are data, never shell command fragments. */
sealed interface ResourceCreation {
    val name: String
    val directory: String?

    /**
     * Who the new window's AI runs as (`run-as.v1`); null or [RunAs.Mode.CURRENT] keeps the
     * connected user, as before the contract. Its password is never logged or stored here: see
     * [RunAs.toString].
     */
    val runAs: RunAs?

    /** Whether the AI starts with `IS_SANDBOX=1`; what travels also depends on [RunAs.sandboxLocked]. */
    val isSandbox: Boolean

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
        /** Who the first window runs as; only sent when [initialTerminal] asks for one. */
        override val runAs: RunAs? = null,
        override val isSandbox: Boolean = false,
    ) : ResourceCreation
    data class Terminal(
        val workspaceID: String,
        override val name: String,
        override val directory: String?,
        val tmuxSession: String?,
        val agentID: String = "terminal",
        override val runAs: RunAs? = null,
        override val isSandbox: Boolean = false,
    ) : ResourceCreation {
        /**
         * Whether this window can be asked of [workspace]. A local box never takes a tmux name
         * (its session is the window's own); an SSH box may take one, and without it the machine
         * picks one. Any agent the box advertises is allowed, SSH included: requiring a typed
         * session and allowing only a plain terminal over SSH made it impossible to start an AI
         * on a server from the phone.
         */
        fun isAllowedIn(workspace: RemoteWorkspace): Boolean = isValid() && workspace.id == workspaceID &&
            workspace.isSSH != null && (workspace.isSSH == true || tmuxSession == null) &&
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
        if (runAs?.isValid() == false) return false
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
                (tmuxSession == null || Regex("[a-z0-9_](?:[a-z0-9_-]{0,38}[a-z0-9_])?").matches(tmuxSession))
        }
    }

    companion object {
        /** Matches the machines' own cap, so an oversized command is refused before it travels. */
        const val MAX_CONNECT_COMMAND_BYTES = 4096
    }
}
