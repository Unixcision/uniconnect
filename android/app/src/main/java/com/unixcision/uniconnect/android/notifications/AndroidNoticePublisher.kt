package com.unixcision.uniconnect.android.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.unixcision.uniconnect.android.MainActivity
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NoticePublisher
import com.unixcision.uniconnect.android.domain.RemoteNotice

/** Notifications contain no terminal output, agent prompt or remote notification body. */
class AndroidNoticePublisher(private val context: Context) : NoticePublisher {
    init {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CONNECTION_CHANNEL, context.getString(R.string.connection_channel), NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel(NOTICE_CHANNEL, context.getString(R.string.notice_channel), NotificationManager.IMPORTANCE_DEFAULT).apply {
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
    }

    fun hasPermission(): Boolean =
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun connection(connected: Boolean): Notification {
        val stop = PendingIntent.getService(context, 0, Intent(context, ConnectedMachineService::class.java).setAction(ConnectedMachineService.STOP_ALL), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(context, CONNECTION_CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(if (connected) R.string.connection_service_active else R.string.connection_service_connecting))
            .setContentText(context.getString(R.string.connection_service_detail)).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, context.getString(R.string.stop_connections), stop).build()
    }

    override suspend fun publish(machine: Machine, notice: RemoteNotice): Boolean {
        if (!hasPermission()) return false
        if (context.getSystemService(NotificationManager::class.java).getNotificationChannel(NOTICE_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        val route = Uri.Builder().scheme("uniconnect").authority("notice").appendPath(machine.id).appendPath(notice.id).build()
        val intent = Intent(context, MainActivity::class.java).setData(route)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MACHINE_ID, machine.id).putExtra(WORKSPACE_ID, notice.workspaceID).putExtra(WINDOW_ID, notice.windowID)
        val open = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val publicVersion = NotificationCompat.Builder(context, NOTICE_CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.app_name)).setContentText(context.getString(R.string.notice_private_public)).build()
        val notification = NotificationCompat.Builder(context, NOTICE_CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.notice_title)).setContentText(context.getString(R.string.notice_machine, machine.name))
            .setContentIntent(open).setAutoCancel(true).setOnlyAlertOnce(true).setWhen(notice.createdAt)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(publicVersion).build()
        // Stable tag + id replaces a pending notification if the process died between publish and journal commit.
        context.getSystemService(NotificationManager::class.java).notify("${machine.id}/${notice.id}", 1, notification)
        return true
    }

    companion object {
        const val CONNECTION_CHANNEL = "private_connections"
        const val NOTICE_CHANNEL = "private_machine_notices"
        const val MACHINE_ID = "notice_machine_id"
        const val WORKSPACE_ID = "notice_workspace_id"
        const val WINDOW_ID = "notice_window_id"
    }
}
