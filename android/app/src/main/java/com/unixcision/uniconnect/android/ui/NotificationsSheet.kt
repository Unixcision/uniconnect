package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Avisos, from the side menu: every machine with its own switch for notifications, so they can be
 * turned on or off for all of them without opening each one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotificationsSheet(
    machines: List<Machine>,
    connected: (Machine) -> Boolean,
    links: Map<String, NotificationLinkState>,
    onEnable: (Machine) -> Unit,
    onDisable: (Machine) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = UniTheme.colors
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = colors.outline) },
    ) {
        Column(
            Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            SheetHeader(
                icon = { Icon(Icons.Rounded.NotificationsActive, null, tint = colors.accent) },
                title = stringResource(R.string.notices_title),
                note = stringResource(R.string.notices_note),
                tone = colors.accent,
            )
            if (machines.isEmpty()) Text(stringResource(R.string.notices_no_machines), color = colors.muted, style = MaterialTheme.typography.bodyMedium)
            machines.forEach { machine ->
                Text(machine.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = UniTheme.type.identifierFamily)
                NotificationConnectionCard(links[machine.id], connected(machine), onEnable = { onEnable(machine) }, onDisable = { onDisable(machine) })
            }
        }
    }
}
