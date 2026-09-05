package com.unixcision.uniconnect.android

import android.os.Bundle
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationManagerCompat
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.CreationExtras
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.notifications.AndroidNoticePublisher
import java.util.UUID
import com.unixcision.uniconnect.android.ui.MachinesScreen
import com.unixcision.uniconnect.android.ui.MachinesViewModel
import com.unixcision.uniconnect.android.ui.UniConnectTheme

class MainActivity : ComponentActivity() {
    private lateinit var model: MachinesViewModel
    private var notificationMachineID: String? = null
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
        val machineID = notificationMachineID
        notificationMachineID = null
        if (allowed && machineID != null) model.enableNotifications(machineID) else model.notificationPermissionDenied()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        // Animate the native splash out when the first frame is ready; never wait on a timer.
        splash.setOnExitAnimationListener { provider ->
            provider.view.animate().alpha(0f).setDuration(180).withEndAction { provider.remove() }.start()
        }
        val container = (application as UniConnectApplication).container
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                require(modelClass == MachinesViewModel::class.java)
                @Suppress("UNCHECKED_CAST")
                return MachinesViewModel(container.machines, container.machineClient, container.notificationConnections) as T
            }
        }
        model = ViewModelProvider(this, factory)[MachinesViewModel::class.java]
        handleNotice(intent)
        setContent { UniConnectTheme { MachinesScreen(model, ::requestNotifications) } }
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleNotice(intent) }

    private fun handleNotice(intent: Intent?) {
        val machineID = intent?.getStringExtra(AndroidNoticePublisher.MACHINE_ID) ?: return
        val workspaceID = intent.getStringExtra(AndroidNoticePublisher.WORKSPACE_ID) ?: return
        val windowID = intent.getStringExtra(AndroidNoticePublisher.WINDOW_ID)
        if (runCatching { UUID.fromString(machineID); UUID.fromString(workspaceID); windowID?.let(UUID::fromString) }.isFailure) return
        model.openNotice(NoticeRoute(machineID, workspaceID, windowID))
        // A rotation must not navigate again after the user has moved somewhere else.
        intent.removeExtra(AndroidNoticePublisher.MACHINE_ID)
    }

    private fun requestNotifications(machineID: String) {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notificationMachineID = machineID
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) model.notificationPermissionDenied()
        else model.enableNotifications(machineID)
    }
}
