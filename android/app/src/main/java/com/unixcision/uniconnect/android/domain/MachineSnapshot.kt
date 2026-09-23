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
     * Whether this machine lists, reads and deletes what the phone has sent it (`inbox.v1`).
     *
     * Without it the attach sheet shows no gallery and the settings no meter for this machine:
     * there is nothing to ask it and no way to free its space from here.
     */
    val keepsInbox: Boolean get() = INBOX in capabilities

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

        /** The host implements mobile.inbox.list/read/delete (inbox.v1). */
        const val INBOX = "inbox.v1"
    }
}
