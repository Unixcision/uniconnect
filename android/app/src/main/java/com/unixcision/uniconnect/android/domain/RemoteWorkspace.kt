package com.unixcision.uniconnect.android.domain

data class RemoteWorkspace(
    val id: String,
    val name: String,
    val isSSH: Boolean?,
    val windows: List<RemoteWindow>,
    val availableAgentTargets: List<RemoteAgentTarget> = emptyList(),
)
