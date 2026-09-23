package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AttachPaste
import com.unixcision.uniconnect.android.domain.FilePutLocation
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * «Ya en el equipo»: lo que este móvil ya mandó al equipo de la ventana, lo nuevo primero, en
 * una cuadrícula con miniatura. Tocar abre la vista previa; el botón de la esquina lo vuelve a
 * pegar en la cajita sin abrir nada.
 *
 * Pegar solo se ofrece donde la IA de la ventana puede leer el archivo, que es el propio equipo:
 * en una ventana SSH la ruta del equipo no le sirve, así que se copia en vez de pegarse.
 */
@Composable
internal fun InboxGallery(inbox: InboxViewModel, target: AttachTarget, onPaste: (InboxEntry) -> Unit) {
    val state by inbox.state.collectAsStateWithLifecycle()
    val machine = target.machine
    val mine = state.inboxes[machine.id]
    val listing = mine?.listing
    val colors = UniTheme.colors
    val pasteable = AttachPaste.shouldPaste(FilePutLocation.HOST, target.isSSH)
    var open by remember { mutableStateOf<InboxEntry?>(null) }
    LaunchedEffect(machine.id) { inbox.refresh(machine) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel(stringResource(R.string.inbox_on_machine, machine.name)) {
            listing?.let { Text("${inboxFiles(it.count)} · ${formatSize(it.totalBytes)}", style = MaterialTheme.typography.labelSmall, color = colors.muted) }
            if (mine?.loading == true) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.accent)
            } else {
                IconButton(onClick = { inbox.refresh(machine) }, Modifier.size(28.dp)) {
                    Icon(Icons.Rounded.Refresh, stringResource(R.string.inbox_refresh), Modifier.size(16.dp), tint = colors.muted)
                }
            }
        }
        val failure = mine?.failure
        if (failure != null) Text(failure.inboxMessage(machine.name), style = MaterialTheme.typography.bodySmall, color = colors.danger)
        when {
            listing == null -> if (failure == null) Text(stringResource(R.string.inbox_loading, machine.name), style = MaterialTheme.typography.bodySmall, color = colors.muted)
            listing.entries.isEmpty() -> Text(stringResource(R.string.inbox_empty, machine.name), style = MaterialTheme.typography.bodySmall, color = colors.muted)
            else -> {
                listing.entries.chunked(COLUMNS).forEach { row ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                        row.forEach { entry ->
                            key(entry.path) {
                                InboxTile(inbox, state, machine, entry, pasteable, Modifier.weight(1f), onOpen = { open = entry }, onPaste = { onPaste(entry) })
                            }
                        }
                        repeat(COLUMNS - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
                if (listing.count > listing.entries.size) {
                    TextButton(onClick = { inbox.showMore(machine) }, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.inbox_show_more, listing.entries.size, listing.count), style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
    }
    open?.let { entry ->
        InboxPreviewDialog(inbox, machine, entry, pasteable, onPaste = { open = null; onPaste(entry) }, onDismiss = { open = null })
    }
}

private const val COLUMNS = 3
