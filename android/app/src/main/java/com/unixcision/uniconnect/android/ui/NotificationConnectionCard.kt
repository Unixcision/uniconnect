package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.NotificationLinkState

@Composable
fun NotificationConnectionCard(link: NotificationLinkState?, canEnable: Boolean, onEnable: () -> Unit, onDisable: () -> Unit) {
    var confirming by remember { mutableStateOf(false) }
    val active = link == NotificationLinkState.Connecting || link == NotificationLinkState.Connected || link == NotificationLinkState.Reconnecting
    Surface(shape = RoundedCornerShape(20.dp), color = Brand.Surface) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(R.string.mobile_notices), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(when (link) {
                NotificationLinkState.Connected -> R.string.notices_connected
                NotificationLinkState.Connecting, NotificationLinkState.Reconnecting -> R.string.notices_reconnecting
                NotificationLinkState.ApprovalRequired -> R.string.approval_required
                NotificationLinkState.Failed -> R.string.notices_failed
                null -> R.string.notices_off
            }), style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
            TextButton(onClick = { if (active) onDisable() else confirming = true }, enabled = active || canEnable) {
                Text(stringResource(if (active) R.string.disable_notices else R.string.enable_notices))
            }
        }
    }
    if (confirming) AlertDialog(onDismissRequest = { confirming = false },
        title = { Text(stringResource(R.string.enable_notices)) },
        text = { Text(stringResource(R.string.notices_opt_in_detail)) },
        confirmButton = { TextButton(onClick = { confirming = false; onEnable() }) { Text(stringResource(R.string.activate)) } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.cancel)) } })
}
