package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.ui.components.GlassCard

@Composable
fun NotificationConnectionCard(link: NotificationLinkState?, canEnable: Boolean, onEnable: () -> Unit, onDisable: () -> Unit) {
    var confirming by remember { mutableStateOf(false) }
    val active = link == NotificationLinkState.Connecting || link == NotificationLinkState.Connected || link == NotificationLinkState.Reconnecting
    val tone = when (link) {
        NotificationLinkState.Connected -> UniTheme.colors.success
        NotificationLinkState.Connecting, NotificationLinkState.Reconnecting -> UniTheme.colors.accent
        NotificationLinkState.ApprovalRequired, NotificationLinkState.Failed -> UniTheme.colors.warning
        null -> UniTheme.colors.muted
    }
    GlassCard(Modifier.fillMaxWidth(), accent = if (active) tone else null) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(42.dp).background(tone.copy(alpha = .14f), UniTheme.shapes.chip), contentAlignment = Alignment.Center) {
                Icon(if (active) Icons.Rounded.NotificationsActive else Icons.Rounded.Notifications, null, tint = tone)
            }
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.mobile_notices), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(when (link) {
                    NotificationLinkState.Connected -> R.string.notices_connected
                    NotificationLinkState.Connecting, NotificationLinkState.Reconnecting -> R.string.notices_reconnecting
                    NotificationLinkState.ApprovalRequired -> R.string.approval_required
                    NotificationLinkState.Failed -> R.string.notices_failed
                    null -> R.string.notices_off
                }), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted, maxLines = 3)
            }
            Switch(
                checked = active, enabled = active || canEnable,
                onCheckedChange = { if (active) onDisable() else confirming = true },
                colors = SwitchDefaults.colors(checkedThumbColor = UniTheme.colors.onAccent, checkedTrackColor = UniTheme.colors.success, uncheckedTrackColor = UniTheme.colors.surfaceRaised, uncheckedBorderColor = UniTheme.colors.outline),
            )
        }
    }
    if (confirming) AlertDialog(
        onDismissRequest = { confirming = false },
        containerColor = UniTheme.colors.surfaceRaised,
        icon = { Icon(Icons.Rounded.NotificationsActive, null, tint = UniTheme.colors.success) },
        title = { Text(stringResource(R.string.enable_notices)) },
        text = { Text(stringResource(R.string.notices_opt_in_detail), color = UniTheme.colors.muted) },
        confirmButton = { TextButton(onClick = { confirming = false; onEnable() }) { Text(stringResource(R.string.activate), color = UniTheme.colors.success) } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.cancel)) } },
    )
}
