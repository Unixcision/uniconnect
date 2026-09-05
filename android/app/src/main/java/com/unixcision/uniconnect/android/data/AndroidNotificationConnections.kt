package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import com.unixcision.uniconnect.android.domain.NotificationConnectionControl
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.notifications.ConnectedMachineService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Platform adapter; the activity calls enable only after the explicit permission/continuity opt-in.
 * The opted-in machine IDs are persisted so an app update or a process kill does not silently
 * switch the user's notices off: [restore] re-arms them on the next launch.
 */
class AndroidNotificationConnections(
    private val context: Context,
    private val store: DataStore<Preferences>,
    private val scope: CoroutineScope,
) : NotificationConnectionControl {
    private val mutableStates = MutableStateFlow<Map<String, NotificationLinkState>>(emptyMap())
    override val states = mutableStates.asStateFlow()
    private val enabledKey = stringSetPreferencesKey("notification_links")

    override fun enable(machineID: String) {
        report(machineID, NotificationLinkState.Connecting)
        try {
            ContextCompat.startForegroundService(context, Intent(context, ConnectedMachineService::class.java)
                .setAction(ConnectedMachineService.ENABLE).putExtra(ConnectedMachineService.MACHINE_ID, machineID))
            scope.launch { store.edit { it[enabledKey] = (it[enabledKey] ?: emptySet()) + machineID } }
        } catch (_: Exception) { report(machineID, NotificationLinkState.Failed) }
    }

    override fun disable(machineID: String) {
        scope.launch { store.edit { it[enabledKey] = (it[enabledKey] ?: emptySet()) - machineID } }
        context.startService(Intent(context, ConnectedMachineService::class.java)
            .setAction(ConnectedMachineService.DISABLE).putExtra(ConnectedMachineService.MACHINE_ID, machineID))
    }

    override fun restore() {
        scope.launch {
            val remembered = runCatching { store.data.first()[enabledKey] }.getOrNull().orEmpty()
            remembered.filter { mutableStates.value[it] == null }.forEach(::enable)
        }
    }

    fun report(machineID: String, value: NotificationLinkState) { mutableStates.update { it + (machineID to value) } }
    fun remove(machineID: String) { mutableStates.update { it - machineID } }
    fun clearActive() { mutableStates.update { entries -> entries.filterValues { it == NotificationLinkState.Failed || it == NotificationLinkState.ApprovalRequired } } }
}
