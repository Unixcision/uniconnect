package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import com.unixcision.uniconnect.android.domain.NotificationConnectionControl
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.notifications.ConnectedMachineService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Platform adapter; the activity calls enable only after the explicit permission/continuity opt-in. */
class AndroidNotificationConnections(private val context: Context) : NotificationConnectionControl {
    private val mutableStates = MutableStateFlow<Map<String, NotificationLinkState>>(emptyMap())
    override val states = mutableStates.asStateFlow()

    override fun enable(machineID: String) {
        report(machineID, NotificationLinkState.Connecting)
        try {
            ContextCompat.startForegroundService(context, Intent(context, ConnectedMachineService::class.java)
                .setAction(ConnectedMachineService.ENABLE).putExtra(ConnectedMachineService.MACHINE_ID, machineID))
        } catch (_: Exception) { report(machineID, NotificationLinkState.Failed) }
    }

    override fun disable(machineID: String) {
        context.startService(Intent(context, ConnectedMachineService::class.java)
            .setAction(ConnectedMachineService.DISABLE).putExtra(ConnectedMachineService.MACHINE_ID, machineID))
    }

    fun report(machineID: String, value: NotificationLinkState) { mutableStates.update { it + (machineID to value) } }
    fun remove(machineID: String) { mutableStates.update { it - machineID } }
    fun clearActive() { mutableStates.update { entries -> entries.filterValues { it == NotificationLinkState.Failed || it == NotificationLinkState.ApprovalRequired } } }
}
