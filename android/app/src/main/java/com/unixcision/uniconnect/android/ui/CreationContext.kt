package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.RemoteWorkspace

/**
 * Captured when opening the form, so navigation cannot silently change a pending mutation's target.
 * [firstWindow] marks the second step of workspace creation: the box exists and has no windows yet.
 */
data class CreationContext(
    val machineID: String,
    val workspace: RemoteWorkspace?,
    val sshSources: List<RemoteWorkspace>,
    val firstWindow: Boolean = false,
    /** Whether this machine accepts a connection command typed here (`ssh_create.v1`). */
    val takesNewSSH: Boolean = false,
) {
    /** Whether an SSH box can be made at all: by writing a new connection or by reusing one. */
    val allowsSSH: Boolean get() = takesNewSSH || sshSources.isNotEmpty()
}
