package com.unixcision.uniconnect.android.domain

/** An opaque launch ID and display name advertised by this workspace's host. */
data class RemoteAgentTarget(val id: String, val title: String) {
    init {
        require(id.isNotBlank() && id.trim() == id && id.toByteArray(Charsets.UTF_8).size <= 128 && id.none { it.isISOControl() })
        require(title.isNotBlank())
    }
}
