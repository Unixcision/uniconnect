package com.unixcision.uniconnect.android.ui.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/*
 * The two connection messages of a machine screen. They carry decisions (which text, whether the
 * button is enabled), so every design uses these instead of copying them; tokens dress them.
 */

/** A machine never read: why, and the button that tries. Shown instead of the workspaces. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MachineOfflineCard(model: MachineModel, onConnect: () -> Unit, modifier: Modifier = Modifier) {
    val pending = model.error == R.string.approval_required
    val tone = if (pending) UniTheme.colors.warning else UniTheme.colors.accent
    GlassCard(modifier.fillMaxWidth(), accent = tone) {
        Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(44.dp).background(tone.copy(alpha = .14f), UniTheme.shapes.chip), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Lock, null, tint = tone)
            }
            Text(stringResource(if (pending) R.string.approval_pending_title else R.string.not_connected_title), style = MaterialTheme.typography.titleLarge)
            Text(stringResource(model.error ?: R.string.not_connected_detail), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyMedium)
            Button(onClick = onConnect, enabled = !model.checking, modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button, contentPadding = PaddingValues(16.dp)) {
                if (model.checking) LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.onAccent)
                else Icon(Icons.Rounded.Sync, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(if (model.checking) R.string.checking_machine else if (model.error != null) R.string.retry else R.string.check_connection), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/**
 * A machine read before but not answering now: the list below is the last one known, so it says
 * so and offers to check again. Shown above the workspaces.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MachineStaleBanner(model: MachineModel, onConnect: () -> Unit, modifier: Modifier = Modifier) {
    GlassCard(modifier.fillMaxWidth(), accent = UniTheme.colors.warning) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (model.checking) LoadingIndicator(Modifier.size(28.dp), color = UniTheme.colors.warning) else Icon(Icons.Rounded.Sync, null, tint = UniTheme.colors.warning)
            Text(stringResource(model.error ?: R.string.checking_machine), Modifier.weight(1f), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
            if (!model.checking) TextButton(onClick = onConnect) { Text(stringResource(R.string.check_connection)) }
        }
    }
}
