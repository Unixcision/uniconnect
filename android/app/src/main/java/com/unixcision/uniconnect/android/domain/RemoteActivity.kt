package com.unixcision.uniconnect.android.domain

/** One window's activity as the host reported it, with which source decided and which agent. */
data class RemoteActivity(val state: ActivityState, val source: String? = null, val agent: String? = null, val sinceEpochSeconds: Long? = null)
