package com.unixcision.uniconnect.android.domain

/** Notification navigation never selects an unrelated terminal or creates a missing one. */
data class NoticeRoute(val machineID: String, val workspaceID: String, val windowID: String?)
