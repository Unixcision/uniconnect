package com.unixcision.uniconnect.android.domain

/**
 * What the host says it has: its name, its workspaces, and the optional features it advertises.
 *
 * [capabilities] is the host's own list (`capabilities` in the workspace list); a host that keeps
 * favourites and order for its clients announces ``BOX_UPDATE`` there, one that takes files over
 * the private connection announces ``FILE_PUT``, one that turns recorded audio into text
 * announces ``TRANSCRIBE``, and one that accepts a connection command typed on the phone
 * announces ``SSH_CREATE``. Nothing is inferred from error codes: an absent
 * capability means the phone keeps those on its own or goes another way.
 */
data class MachineSnapshot(val serverName: String, val workspaces: List<RemoteWorkspace>, val capabilities: Set<String> = emptySet()) {
    val keepsBoxes: Boolean get() = BOX_UPDATE in capabilities

    /** Whether `mobile.file.begin/chunk/commit/abort` can be used against this host. */
    val putsFiles: Boolean get() = FILE_PUT in capabilities

    /** Whether `mobile.audio.transcribe` can be used against this host. */
    val transcribes: Boolean get() = TRANSCRIBE in capabilities

    /**
     * Whether a connection command typed here can be sent to this host.
     *
     * Without it the phone can still make an SSH box, but only by reusing the credential of one
     * the machine already holds: a machine that does not announce this has no way to validate or
     * store a new command, and sending one would be dropped without a word.
     */
    val takesNewSSH: Boolean get() = SSH_CREATE in capabilities

    /**
     * Whether this machine can relaunch its agents on request.
     *
     * A machine that does not announce it is never sent the call and never shows the action: the
     * alternative is a button that looks like it worked and did nothing at all.
     */
    val relaunches: Boolean get() = RELAUNCH in capabilities

    /**
     * Whether «Relanzar IA de esta ventana» is worth offering for one window (`relaunch-v1`, D7).
     *
     * A host after D7 announces, next to `relaunch.v1`, one [RelaunchCell] token per agent and kind
     * of window it can relaunch (`relaunch.v1.claude.local`, …). Then the entry shows only when the
     * pair of this window is announced or, when the phone does not know which agent runs there,
     * when some pair of its kind is. A host from before D7 announces no pair at all: the entry shows
     * as it always did and the plan explains, target by target, what it cannot do.
     *
     * The token is a hint for the interface, never an authorisation: the plan still excludes with a
     * cause. Workspace and machine scopes keep asking for `relaunch.v1` alone ([relaunches]).
     *
     * @param isSSH the kind of the window's workspace, or null when the host did not say.
     * @param provider the agent the host sees in that window (`activity.agent`), or null.
     */
    fun relaunchesWindow(isSSH: Boolean?, provider: String?): Boolean {
        if (!relaunches) return false
        val cells = capabilities.mapNotNull(RelaunchCell::parse)
        if (cells.isEmpty()) return true
        val kind = when (isSSH) {
            true -> RelaunchCell.SSH
            false -> RelaunchCell.LOCAL
            null -> null
        }
        val agent = canonicalAgent(provider)
        return cells.any { cell -> (kind == null || cell.kind == kind) && (agent == null || cell.provider == agent) }
    }

    /**
     * Whether this machine can update Claude on request (`agent.update`, `relaunch.v1.update`).
     *
     * Workspace and machine scopes ask for this alone: the plan says which windows are Claude and
     * excludes the rest with `proveedor_no_soportado`.
     */
    val updatesClaude: Boolean get() = relaunches && UPDATE in capabilities

    /**
     * Whether «Actualizar Claude» is worth offering for one window.
     *
     * The host announces `relaunch.v1.update.claude.<local|ssh>` for each kind of window where it
     * does it. The entry shows when the pair of this window is announced (or some pair, when the
     * phone does not know its kind) and the window's agent is Claude, or unknown.
     *
     * @param isSSH the kind of the window's workspace, or null when the host did not say.
     * @param provider the agent the host sees in that window (`activity.agent`), or null.
     */
    fun updatesClaudeWindow(isSSH: Boolean?, provider: String?): Boolean {
        if (!updatesClaude) return false
        val agent = canonicalAgent(provider)
        if (agent != null && agent != CLAUDE) return false
        val kinds = when (isSSH) {
            true -> listOf(RelaunchCell.SSH)
            false -> listOf(RelaunchCell.LOCAL)
            null -> listOf(RelaunchCell.LOCAL, RelaunchCell.SSH)
        }
        return kinds.any { kind -> "$UPDATE.$CLAUDE.$kind" in capabilities }
    }

    /** The wire id of an agent as the host names it; the Mac names Antigravity by its catalogue id. */
    private fun canonicalAgent(provider: String?): String? =
        provider?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }?.let { if (it == "antigravity") "agy" else it }

    /**
     * Whether this machine lists, reads and deletes what the phone has sent it (`inbox.v1`).
     *
     * Without it the attach sheet shows no gallery and the settings no meter for this machine:
     * there is nothing to ask it and no way to free its space from here.
     */
    val keepsInbox: Boolean get() = INBOX in capabilities

    /**
     * Whether this machine answers `mobile.terminal.details` (`window_details.v1`).
     *
     * Without it the terminal menu shows no «Detalles»: an older host would answer
     * `method_not_found`, and an entry that only ever fails is worse than no entry.
     */
    val describesWindows: Boolean get() = WINDOW_DETAILS in capabilities

    /**
     * Whether a workspace or a window can be closed from here (`workspace.close`, `terminal.close`,
     * `box-close.v1`).
     *
     * Without it the long-press sheet offers no «Cerrar»: an older host would answer
     * `method_not_found`, and a destructive entry that never works is worse than none.
     */
    val closesBoxes: Boolean get() = BOX_CLOSE in capabilities

    /**
     * Whether a new window can be asked to run as root or as another user, and with `IS_SANDBOX=1`
     * (`run-as.v1`).
     *
     * An older host would ignore the parameters and start the AI as the connected user, which is
     * worse than not offering the choice at all.
     */
    val runsAs: Boolean get() = RUN_AS in capabilities

    /**
     * Whether each window says when its last prompt was written (`last_prompt_at`,
     * `recent-prompts.v1`).
     *
     * Without it a missing time means «not sent», not «never prompted», so the «Recientes» tab
     * would be empty for the wrong reason and is not offered.
     */
    val listsRecentPrompts: Boolean get() = RECENT_PROMPTS in capabilities

    /**
     * Whether this machine tells, read live, which account each of its AIs is using
     * (`mobile.accounts.list`, `accounts.v1`).
     *
     * Without it «Cuentas de IA» leaves this machine out: an older host would answer
     * `method_not_found`.
     */
    val listsAccounts: Boolean get() = ACCOUNTS in capabilities

    /**
     * Whether this machine can spend a free Codex reset of an account (`mobile.accounts.codex_reset`,
     * `accounts.codex_reset.v1`). The only write of accounts-v1; without it the button is not shown.
     */
    val resetsCodex: Boolean get() = CODEX_RESET in capabilities

    companion object {
        /** The host implements mobile.workspace.update and mobile.terminal.update. */
        const val BOX_UPDATE = "box_update"

        /** The host implements the file_put.v1 contract. */
        const val FILE_PUT = "file_put.v1"

        /** The host implements the transcribe.v1 contract. */
        const val TRANSCRIBE = "transcribe.v1"

        /** The host accepts `connect_command` in workspace.create (ssh_create.v1). */
        const val SSH_CREATE = "ssh_create.v1"

        /** The host implements relaunch.plan/apply/status (relaunch.v1). */
        const val RELAUNCH = "relaunch.v1"

        /** The host implements `agent.update` («Actualizar Claude»); per kind, `relaunch.v1.update.claude.<tipo>`. */
        const val UPDATE = "relaunch.v1.update"

        /** The host saves and restores background monitors and drafts when it relaunches. */
        const val RESTORES = "relaunch.v1.restaura"

        private const val CLAUDE = "claude"

        /** The host implements mobile.inbox.list/read/delete (inbox.v1). */
        const val INBOX = "inbox.v1"

        /** The host implements mobile.terminal.details (window_details.v1). */
        const val WINDOW_DETAILS = "window_details.v1"

        /** The host implements workspace.close and terminal.close (box-close.v1). */
        const val BOX_CLOSE = "box_close"

        /** The host accepts `run_as` and `is_sandbox` when creating a window (run-as.v1). */
        const val RUN_AS = "run_as"

        /** Every window in the list carries `last_prompt_at` (recent-prompts.v1). */
        const val RECENT_PROMPTS = "recent_prompts"

        /** The host implements mobile.accounts.list (accounts.v1). */
        const val ACCOUNTS = "accounts.v1"

        /** The host implements mobile.accounts.codex_reset (accounts-v1 §5). */
        const val CODEX_RESET = "accounts.codex_reset.v1"
    }
}
