package com.unixcision.uniconnect.android.notifications

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.ServiceCompat
import com.unixcision.uniconnect.android.UniConnectApplication
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.NoticeDeliveryCoordinator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** User-visible continuity of connections to explicitly selected external computers, not a hidden wakeup service. */
class ConnectedMachineService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val jobs = mutableMapOf<String, Job>()
    private val container get() = (application as UniConnectApplication).container
    private lateinit var publisher: AndroidNoticePublisher

    override fun onCreate() { super.onCreate(); publisher = AndroidNoticePublisher(this) }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ENABLE -> {
                val machineID = intent.getStringExtra(MACHINE_ID) ?: return START_NOT_STICKY
                if (!publisher.hasPermission() || (jobs.size >= 8 && machineID !in jobs)) {
                    container.notificationConnections.report(machineID, NotificationLinkState.Failed)
                    if (jobs.isEmpty()) stopSelf()
                    return START_NOT_STICKY
                }
                ServiceCompat.startForeground(this, FOREGROUND_ID, publisher.connection(false),
                    if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0)
                startMachine(machineID)
            }
            DISABLE -> intent.getStringExtra(MACHINE_ID)?.let { id -> jobs.remove(id)?.cancel(); container.notificationConnections.remove(id); stopIfIdle() }
            STOP_ALL -> { val pending = jobs.values.toList(); jobs.clear(); pending.forEach { it.cancel() }; container.notificationConnections.clearActive(); stopSelf() }
            else -> stopSelf()
        }
        // No boot receiver or hidden restart: the user starts another visible connection if Android stops it.
        return START_NOT_STICKY
    }

    private fun startMachine(machineID: String) {
        if (jobs[machineID]?.isActive == true) return
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val machine = container.machines.machines.first().firstOrNull { it.id == machineID } ?: return@launch
                val deliveries = NoticeDeliveryCoordinator(container.noticeDeliveries, publisher)
                var retry = 0
                while (true) {
                    try {
                        container.notificationConnections.report(machineID, NotificationLinkState.Connecting)
                        container.notificationClient.observe(machine).collect { batch ->
                            retry = 0
                            container.notificationConnections.report(machineID, NotificationLinkState.Connected)
                            refreshForeground()
                            deliveries.deliver(machine, batch)
                        }
                        break
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) {
                        val code = (failure as? MachineFailure.Rejected)?.code
                        val permanent = failure is NoticeDeliveryCoordinator.DeliveryDisabled || failure is MachineFailure.ProtocolMismatch || code in setOf("approval_required", "forbidden", "unauthorized", "method_not_found")
                        container.notificationConnections.report(machineID, when {
                            code == "approval_required" -> NotificationLinkState.ApprovalRequired
                            permanent -> NotificationLinkState.Failed
                            else -> NotificationLinkState.Reconnecting
                        })
                        refreshForeground()
                        if (permanent) break
                        delay(minOf(2_000L shl retry.coerceAtMost(4), 30_000L))
                        retry += 1
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { container.notificationConnections.report(machineID, NotificationLinkState.Failed) }
            finally {
                if (jobs[machineID] === coroutineContext[Job]) jobs.remove(machineID)
                stopIfIdle()
            }
        }
        jobs[machineID] = job
        job.start()
    }

    private fun refreshForeground() {
        val connected = container.notificationConnections.states.value.values.any { it == NotificationLinkState.Connected }
        getSystemService(android.app.NotificationManager::class.java).notify(FOREGROUND_ID, publisher.connection(connected))
    }

    private fun stopIfIdle() { if (jobs.isEmpty()) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() } }
    override fun onDestroy() { scope.cancel(); container.notificationConnections.clearActive(); super.onDestroy() }

    companion object {
        const val ENABLE = "com.unixcision.uniconnect.ENABLE_PRIVATE_CONNECTION"
        const val DISABLE = "com.unixcision.uniconnect.DISABLE_PRIVATE_CONNECTION"
        const val STOP_ALL = "com.unixcision.uniconnect.STOP_PRIVATE_CONNECTIONS"
        const val MACHINE_ID = "machine_id"
        const val FOREGROUND_ID = 100
    }
}
