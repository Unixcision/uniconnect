package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CleaningServices
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxCandidate
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Ajustes › Adjuntos: cuánto ocupa la bandeja de entrada de cada equipo y el botón para liberar
 * espacio. Cada equipo se pregunta al abrir Ajustes; los que no se pueden medir dicen por qué.
 */
@Composable
internal fun ColumnScope.InboxSettingsSection(inbox: InboxViewModel, candidates: List<InboxCandidate>) {
    val state by inbox.state.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    var cleaning by remember { mutableStateOf<Machine?>(null) }
    val available = candidates.filter { it.available }.map { it.machine }
    LaunchedEffect(available.map { it.id }) { available.forEach { inbox.refresh(it) } }
    Text(stringResource(R.string.settings_inbox_note), color = colors.muted, style = MaterialTheme.typography.bodySmall)
    if (candidates.isEmpty()) Text(stringResource(R.string.settings_inbox_none), color = colors.muted, style = MaterialTheme.typography.bodySmall)
    candidates.forEach { candidate ->
        val machine = candidate.machine
        if (!candidate.available) {
            Text(
                stringResource(if (!candidate.connected) R.string.settings_inbox_offline else R.string.settings_inbox_unsupported, machine.name),
                Modifier.padding(top = 6.dp), color = colors.muted, style = MaterialTheme.typography.bodySmall,
            )
            return@forEach
        }
        val mine = state.inboxes[machine.id]
        val listing = mine?.listing
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(machine.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                when {
                    listing != null -> Text(
                        buildString {
                            append(formatSize(listing.totalBytes)); append(" · "); append(inboxFiles(listing.count))
                            listing.oldest?.let { append(" · "); append(stringResource(R.string.settings_inbox_since, inboxDay(it))) }
                        },
                        style = MaterialTheme.typography.bodySmall, color = colors.muted,
                    )
                    mine?.failure != null -> Text(mine.failure.inboxMessage(machine.name), style = MaterialTheme.typography.bodySmall, color = colors.danger)
                    else -> Text(stringResource(R.string.inbox_loading, machine.name), style = MaterialTheme.typography.bodySmall, color = colors.muted)
                }
            }
            if (mine?.loading == true) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.accent)
            } else {
                IconButton(onClick = { inbox.refresh(machine) }, Modifier.size(36.dp)) {
                    Icon(Icons.Rounded.Refresh, stringResource(R.string.inbox_refresh), Modifier.size(18.dp), tint = colors.muted)
                }
            }
        }
        TextButton(
            onClick = { cleaning = machine },
            enabled = (listing?.count ?: 0) > 0,
            contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
        ) {
            Icon(Icons.Rounded.CleaningServices, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
            Text(stringResource(R.string.settings_inbox_free), style = MaterialTheme.typography.labelLarge)
        }
    }
    cleaning?.let { machine -> InboxCleanupDialog(inbox, machine, onDismiss = { cleaning = null }) }
}
