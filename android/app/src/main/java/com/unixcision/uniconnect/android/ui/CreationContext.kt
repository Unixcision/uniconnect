package com.unixcision.uniconnect.android.ui

import com.unixcision.uniconnect.android.domain.RemoteWorkspace

/** Captured when opening the form, so navigation cannot silently change a pending mutation's target. */
data class CreationContext(val machineID: String, val workspace: RemoteWorkspace?, val sshSources: List<RemoteWorkspace>)
