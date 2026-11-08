package com.unixcision.uniconnect.android.domain

/**
 * Which user a new window's AI runs as (`run-as.v1`): the connected one, root, or another user,
 * reached with `sudo` or `su`.
 *
 * [password] is only ever held in memory for the one request that carries it. The machine keeps it
 * in its own vault; the phone never writes it to disk, to the connection diary or to a log, and
 * [toString] never prints it, so a data class that holds this one cannot leak it either.
 */
data class RunAs(
    val mode: Mode,
    val method: Method = Method.SUDO,
    /** The target user; only meaningful with [Mode.USER]. */
    val user: String? = null,
    /** Absent when the machine does not ask for one (sudo without a password). */
    val password: String? = null,
) {
    enum class Mode(val wire: String) {
        /** The user the box connects with, as before this contract. */
        CURRENT("current"),
        ROOT("root"),
        /** The user named in [user]. */
        USER("user"),
    }

    enum class Method(val wire: String) {
        /** The CONNECTED user's password. */
        SUDO("sudo"),
        /** The TARGET user's password. */
        SU("su"),
    }

    /** Whether this asks for a switch at all; [Mode.CURRENT] travels as nothing. */
    val switchesUser: Boolean get() = mode != Mode.CURRENT

    /** Whether the AI ends up as root, also when «Otro usuario» names root. */
    val becomesRoot: Boolean get() = mode == Mode.ROOT || (mode == Mode.USER && user == ROOT_USER)

    /**
     * Whether this can be sent at all. A user must look like a login name, since the machine puts
     * it on a `sudo`/`su` command line; a password may hold any printable character, spaces at
     * either end included (the machines keep it as typed), but no control characters: a newline
     * would answer the prompt early.
     */
    fun isValid(): Boolean {
        if (mode == Mode.USER && (user == null || !USER_NAME.matches(user))) return false
        if (mode != Mode.USER && user != null) return false
        val secret = password?.takeIf { it.isNotEmpty() } ?: return true
        return secret.toByteArray(Charsets.UTF_8).size <= MAX_PASSWORD_BYTES && secret.none { it.isISOControl() }
    }

    override fun toString(): String =
        "RunAs(mode=$mode, method=$method, user=$user, password=${if (password == null) "null" else "•••"})"

    companion object {
        const val ROOT_USER = "root"
        const val MAX_PASSWORD_BYTES = 1024
        private val USER_NAME = Regex("[A-Za-z0-9_][A-Za-z0-9._-]{0,31}")

        /**
         * Whether `IS_SANDBOX=1` is forced for this window and its box must show checked and locked.
         *
         * Claude refuses to start without questions as root unless it is set (`run-as.v1`, decision
         * 2 of 08-11), so for Claude as root the choice is not the reader's to make.
         */
        fun sandboxLocked(runAs: RunAs?, agentID: String?): Boolean = runAs?.becomesRoot == true && agentID == CLAUDE

        /** What travels as `is_sandbox`: what the reader chose, or true when [sandboxLocked]. */
        fun sandboxFor(runAs: RunAs?, agentID: String?, chosen: Boolean): Boolean = chosen || sandboxLocked(runAs, agentID)

        private const val CLAUDE = "claude"
    }
}
