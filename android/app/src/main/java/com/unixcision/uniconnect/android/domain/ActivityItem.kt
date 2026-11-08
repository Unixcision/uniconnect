package com.unixcision.uniconnect.android.domain

/**
 * One window whose AI is doing something worth showing outside its machine, with the route that
 * opens it: who waits for the reader, who works, what changed a moment ago.
 */
data class ActivityItem(
    val route: NoticeRoute,
    val machineName: String,
    val workspaceName: String,
    val windowName: String,
    /** The host's agent token (`claude`, `codex`…), or null for a window with no AI. */
    val agent: String?,
    val state: ActivityState,
    /** Since when the window is in [state], as the host reports it; null when it did not say. */
    val sinceEpochSeconds: Long?,
)
