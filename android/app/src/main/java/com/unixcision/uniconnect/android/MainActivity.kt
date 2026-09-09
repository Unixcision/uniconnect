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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.CreationExtras
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.notifications.AndroidNoticePublisher
import com.unixcision.uniconnect.android.notifications.NoticeCounters
import java.util.UUID
import com.unixcision.uniconnect.android.ui.AttachViewModel
import com.unixcision.uniconnect.android.ui.DictationViewModel
import com.unixcision.uniconnect.android.ui.MachinesScreen
import com.unixcision.uniconnect.android.ui.MachinesViewModel
import com.unixcision.uniconnect.android.ui.UploadViewModel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

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
        applySystemBars(dark = true)
        // Animate the native splash out when the first frame is ready; never wait on a timer.
        splash.setOnExitAnimationListener { provider ->
            provider.view.animate().alpha(0f).setDuration(180).withEndAction { provider.remove() }.start()
        }
        val container = (application as UniConnectApplication).container
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                @Suppress("UNCHECKED_CAST")
                return when (modelClass) {
                    MachinesViewModel::class.java -> MachinesViewModel(container.machines, container.machineClient, container.notificationConnections, container.settings, container.noticeNames, container.drafts, container.boxOverrides)
                    UploadViewModel::class.java -> UploadViewModel(container.fileSender, container.settings, container.uploadHistory, container.contentReader)
                    AttachViewModel::class.java -> AttachViewModel(container.filePutClient, container.fileSender, container.settings, container.contentReader)
                    DictationViewModel::class.java -> DictationViewModel(container.dictation, container.hostDictation)
                    else -> throw IllegalArgumentException("unknown model ${modelClass.name}")
                } as T
            }
        }
        model = ViewModelProvider(this, factory)[MachinesViewModel::class.java]
        val uploads = ViewModelProvider(this, factory)[UploadViewModel::class.java]
        val attachments = ViewModelProvider(this, factory)[AttachViewModel::class.java]
        val dictation = ViewModelProvider(this, factory)[DictationViewModel::class.java]
        handleNotice(intent)
        setContent {
            // The theme wraps the whole app and follows the stored preference as it changes, so a
            // new choice in the settings sheet is on screen at once, sheet included.
            val state by model.state.collectAsStateWithLifecycle()
            UniTheme(state.settings.designTheme, state.settings.colorMode) {
                val dark = UniTheme.colors.isDark
                LaunchedEffect(dark) { applySystemBars(dark) }
                MachinesScreen(model, uploads, attachments, dictation, ::requestNotifications)
            }
        }
    }

    /** Transparent bars whose icons contrast with the ground the theme draws under them. */
    private fun applySystemBars(dark: Boolean) {
        val transparent = android.graphics.Color.TRANSPARENT
        val style = if (dark) SystemBarStyle.dark(transparent) else SystemBarStyle.light(transparent, transparent)
        enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); handleNotice(intent) }

    private fun handleNotice(intent: Intent?) {
        val machineID = intent?.getStringExtra(AndroidNoticePublisher.MACHINE_ID) ?: return
        val workspaceID = intent.getStringExtra(AndroidNoticePublisher.WORKSPACE_ID) ?: return
        val windowID = intent.getStringExtra(AndroidNoticePublisher.WINDOW_ID)
        // Opening the row is the reader looking: the window's count starts again from one.
        intent.getStringExtra(AndroidNoticePublisher.THREAD)?.let(NoticeCounters::clear)
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
