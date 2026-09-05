package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.StateFlow

interface NotificationConnectionControl {
    val states: StateFlow<Map<String, NotificationLinkState>>
    fun enable(machineID: String)
    fun disable(machineID: String)
    /** Re-arms the links the user had enabled before the process died (update, reboot, memory pressure). */
    fun restore() {}
}
