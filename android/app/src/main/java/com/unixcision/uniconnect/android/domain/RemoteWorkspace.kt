package com.unixcision.uniconnect.android.domain

data class RemoteWorkspace(
    val id: String,
    val name: String,
    val isSSH: Boolean?,
    val windows: List<RemoteWindow>,
    val availableAgentTargets: List<RemoteAgentTarget> = emptyList(),
    val isPinned: Boolean = false,
    /** The host's own summary when it sends one; otherwise the phone sums up the windows. */
    val hostActivity: ActivityState? = null,
) {
    val activity: ActivityState get() = hostActivity ?: ActivityState.summarize(windows.map { it.activity?.state ?: ActivityState.UNKNOWN })
}
