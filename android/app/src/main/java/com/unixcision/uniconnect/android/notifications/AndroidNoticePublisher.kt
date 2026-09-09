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
import com.unixcision.uniconnect.android.domain.NoticeNameCatalog
import com.unixcision.uniconnect.android.domain.NoticeNames
import com.unixcision.uniconnect.android.domain.NoticeKind
import com.unixcision.uniconnect.android.domain.RemoteNotice

/** Notifications contain no terminal output, agent prompt or remote notification body. */
class AndroidNoticePublisher(private val context: Context, private val names: NoticeNameCatalog) : NoticePublisher {
    init {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CONNECTION_CHANNEL, context.getString(R.string.connection_channel), NotificationManager.IMPORTANCE_LOW))
        manager.createNotificationChannel(NotificationChannel(NOTICE_CHANNEL, context.getString(R.string.notice_channel), NotificationManager.IMPORTANCE_DEFAULT).apply {
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        })
        manager.createNotificationChannel(NotificationChannel(ATTENTION_CHANNEL, context.getString(R.string.attention_channel), NotificationManager.IMPORTANCE_HIGH).apply {
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
            // Head of the thread: every notice hangs from this one, which keeps the app's logo.
            .setGroup(GROUP).setGroupSummary(true)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, context.getString(R.string.stop_connections), stop).build()
    }

    /** "Workspace · Window" when the phone knows them; the generic line when it does not yet. */
    private fun titleFor(found: NoticeNames): String = when {
        found.workspace != null && found.window != null -> context.getString(R.string.notice_title_window, found.workspace, found.window)
        found.workspace != null -> context.getString(R.string.notice_title_workspace, found.workspace)
        else -> context.getString(R.string.notice_title)
    }

    override suspend fun publish(machine: Machine, notice: RemoteNotice): Boolean {
        if (!hasPermission()) return false
        if (context.getSystemService(NotificationManager::class.java).getNotificationChannel(NOTICE_CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        // One notification per window, updated in place: a chatty agent raises the count, not the pile.
        val thread = threadFor(machine, notice)
        val count = NoticeCounters.increment(thread)
        val route = Uri.Builder().scheme("uniconnect").authority("notice").appendPath(machine.id).appendPath(notice.id).build()
        val intent = Intent(context, MainActivity::class.java).setData(route)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MACHINE_ID, machine.id).putExtra(WORKSPACE_ID, notice.workspaceID).putExtra(WINDOW_ID, notice.windowID).putExtra(THREAD, thread)
        val open = PendingIntent.getActivity(context, thread.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val dismissed = PendingIntent.getBroadcast(context, thread.hashCode(), Intent(context, NoticeDismissReceiver::class.java).putExtra(THREAD, thread), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val attention = notice.kind == NoticeKind.ATTENTION
        val publicVersion = NotificationCompat.Builder(context, NOTICE_CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.app_name)).setContentText(context.getString(R.string.notice_private_public)).build()
        val found = names.lookup(machine.id, notice)
        val title = titleFor(found).let { if (count > 1) context.getString(R.string.notice_title_count, it, count) else it }
        val text = when (notice.kind) {
            NoticeKind.ATTENTION -> context.getString(R.string.notice_text_attention, machine.name)
            NoticeKind.FINISHED -> context.getString(R.string.notice_text_finished, machine.name)
            NoticeKind.INFO -> context.getString(R.string.notice_machine, machine.name)
        }
        val notification = NotificationCompat.Builder(context, if (attention) ATTENTION_CHANNEL else NOTICE_CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title).setContentText(text).setNumber(count)
            // The workspace's monogram, so the notice looks like the box it comes from.
            .apply { found.workspace?.let { setLargeIcon(NoticeMonogram.bitmap(context, it)) } }
            // A question deserves a sound each time; a finished turn only the first time its row appears.
            .setContentIntent(open).setDeleteIntent(dismissed).setAutoCancel(true).setOnlyAlertOnce(!attention)
            .setPriority(if (attention) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(if (attention) NotificationCompat.CATEGORY_MESSAGE else NotificationCompat.CATEGORY_STATUS)
            .setWhen(notice.createdAt).setShowWhen(true).setGroup(GROUP)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(publicVersion).build()
        // Stable tag per window: a new notice from the same window replaces the row instead of adding one.
        context.getSystemService(NotificationManager::class.java).notify(thread, 1, notification)
        return true
    }

    /** The window (or the workspace, when the host names none) a notice belongs to. */
    private fun threadFor(machine: Machine, notice: RemoteNotice): String = "${machine.id}/${notice.workspaceID}/${notice.windowID ?: "-"}"

    companion object {
        const val CONNECTION_CHANNEL = "private_connections"
        const val NOTICE_CHANNEL = "private_machine_notices"
        const val ATTENTION_CHANNEL = "private_machine_attention"
        const val THREAD = "notice_thread"
        /** One thread for everything UniConnect posts: the connection card on top, notices under it. */
        const val GROUP = "com.unixcision.uniconnect.notices"
        const val MACHINE_ID = "notice_machine_id"
        const val WORKSPACE_ID = "notice_workspace_id"
        const val WINDOW_ID = "notice_window_id"
    }
}
