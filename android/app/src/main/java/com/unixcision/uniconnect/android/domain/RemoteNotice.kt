package com.unixcision.uniconnect.android.domain

/** Durable host identity and navigation only; terminal contents are not retained on the phone. */
data class RemoteNotice(val id: String, val workspaceID: String, val windowID: String?, val createdAt: Long, val isRead: Boolean)
