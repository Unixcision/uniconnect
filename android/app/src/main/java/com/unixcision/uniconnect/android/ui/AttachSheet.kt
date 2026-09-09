package com.unixcision.uniconnect.android.ui

import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AttachFile
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AttachPaste
import com.unixcision.uniconnect.android.domain.AttachRoute
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.ui.components.ActionTile
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The clip in a terminal's bar. Opens the quick sheet to attach, and, sheet open or closed, deals
 * once with each finished transfer of this window: pastes its path or link into the composer
 * when the file sits where the window's agent runs, or tells the reader it was kept on the host.
 */
@Composable
fun AttachButton(model: AttachViewModel, target: AttachTarget, draft: String, onDraftChange: (String) -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var open by rememberSaveable { mutableStateOf(false) }
    val mine = remember(state.transfers, target) { state.transfers.filter { it.target.sameWindow(target) } }
    val latestDraft by rememberUpdatedState(draft)
    val latestChange by rememberUpdatedState(onDraftChange)
    LaunchedEffect(mine) {
        val finished = mine.filter { it.status == AttachViewModel.Status.DONE && !it.handled && it.reference != null }
        if (finished.isEmpty()) return@LaunchedEffect
        val (toPaste, kept) = finished.partition { it.pasteable }
        if (toPaste.isNotEmpty()) {
            // Fold locally: the draft the screen holds only catches up after the change is applied.
            var text = latestDraft
            toPaste.forEach { text = AttachPaste.pasteInto(text, requireNotNull(it.reference)) }
            latestChange(text)
            Toast.makeText(context, if (toPaste.any { it.isLink }) R.string.attach_pasted_link else R.string.attach_pasted_path, Toast.LENGTH_SHORT).show()
        }
        if (kept.isNotEmpty()) Toast.makeText(context, R.string.attach_kept_toast, Toast.LENGTH_LONG).show()
        finished.forEach { model.markHandled(it.id) }
    }
    val busy = mine.any { it.status == AttachViewModel.Status.SENDING || it.status == AttachViewModel.Status.PENDING }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Rounded.AttachFile, stringResource(R.string.attach_title), tint = if (busy) UniTheme.colors.accent else UniTheme.colors.muted)
    }
    if (open) AttachSheet(model, target, mine, state.service, onDismiss = { open = false })
}

/**
 * Quick sheet: the three ways to pick, always, and the transfers of this window. When the host
 * cannot take files over the private connection, one visible line above the buttons says the
 * file will go to the fallback service instead, before anything is tapped.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttachSheet(model: AttachViewModel, target: AttachTarget, transfers: List<AttachViewModel.Transfer>, service: UploadService, onDismiss: () -> Unit) {
    var localError by remember { mutableStateOf<Int?>(null) }
    val route = AttachRoute.forHost(takesFiles = target.supportsFilePut)
    // What the reader saw when tapping is what happens when the picker returns, even if the
    // snapshot changed meanwhile; only after process death do the current values stand in.
    var armed by remember { mutableStateOf<Pair<AttachTarget, AttachRoute>?>(null) }
    val pickers = rememberAttachmentPickers(
        onPicked = { uris -> val (destination, way) = armed ?: (target to route); armed = null; model.attach(destination, uris, way) },
        onUnavailable = { armed = null; localError = it },
    )
    val armedPickers = remember(pickers, target, route) {
        AttachmentPickers(
            takePhoto = { armed = target to route; pickers.takePhoto() },
            pickImages = { armed = target to route; pickers.pickImages() },
            pickFiles = { armed = target to route; pickers.pickFiles() },
        )
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = UniTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = UniTheme.colors.outline) },
    ) {
        Column(Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SheetHeader(
                icon = { Icon(Icons.Rounded.AttachFile, null, tint = UniTheme.colors.accent) },
                title = stringResource(R.string.attach_title),
                note = if (target.supportsFilePut) stringResource(R.string.attach_note_host, target.machine.name) else stringResource(R.string.attach_note_window),
                tone = UniTheme.colors.accent,
            )
            // The one line the reader sees before tapping when the file will leave for the fallback service.
            if (!target.supportsFilePut) Text(stringResource(R.string.attach_fallback_line, target.machine.name, service.domain), color = UniTheme.colors.warning, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            PickerTiles(armedPickers)
            localError?.let { ErrorNotice(it) { localError = null } }
            if (transfers.isNotEmpty()) {
                SectionLabel(stringResource(R.string.attach_transfers))
                Column(verticalArrangement = Arrangement.spacedBy(UniTheme.layout.rowGap(UniTheme.spacing))) {
                    transfers.asReversed().forEach { transfer ->
                        key(transfer.id) { TransferRow(transfer, onRetry = { model.retry(transfer.id) }, onDismiss = { model.dismiss(transfer.id) }) }
                    }
                }
            }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.close), color = UniTheme.colors.muted) }
        }
    }
}

@Composable
private fun PickerTiles(pickers: AttachmentPickers) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(UniTheme.spacing.gapSmall)) {
        ActionTile(Icons.Rounded.CameraAlt, stringResource(R.string.upload_take_photo), Modifier.weight(1f), pickers.takePhoto)
        ActionTile(Icons.Rounded.Image, stringResource(R.string.upload_pick_images), Modifier.weight(1f), pickers.pickImages)
        ActionTile(Icons.Rounded.AttachFile, stringResource(R.string.upload_pick_files), Modifier.weight(1f), pickers.pickFiles)
    }
}

/** One attachment: queued, a progress bar, the pasted reference, a kept host copy, or why it failed. */
@Composable
private fun TransferRow(transfer: AttachViewModel.Transfer, onRetry: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val accent = when (transfer.status) {
        AttachViewModel.Status.DONE -> if (transfer.pasteable) colors.success else colors.warning
        AttachViewModel.Status.FAILED -> colors.danger
        AttachViewModel.Status.SENDING -> colors.accent
        AttachViewModel.Status.PENDING -> null
    }
    GlassCard(Modifier.fillMaxWidth(), style = UniTheme.layout.rowsAs, accent = accent) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = UniTheme.layout.rowPadding), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(transfer.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(formatSize(transfer.size), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                if (transfer.status != AttachViewModel.Status.SENDING) IconButton(onClick = onDismiss, Modifier.size(28.dp)) {
                    Icon(Icons.Rounded.Close, stringResource(R.string.upload_remove), Modifier.size(16.dp), tint = colors.muted)
                }
            }
            when (transfer.status) {
                AttachViewModel.Status.PENDING -> Text(stringResource(R.string.upload_queued), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                AttachViewModel.Status.SENDING -> {
                    LinearProgressIndicator(progress = { transfer.fraction }, modifier = Modifier.fillMaxWidth(), color = colors.accent, trackColor = colors.surfaceRaised)
                    Text(stringResource(R.string.attach_sending, (transfer.fraction * 100).toInt()), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                }
                AttachViewModel.Status.DONE -> if (transfer.pasteable) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Rounded.Check, null, Modifier.size(16.dp), tint = colors.success)
                        Text(stringResource(R.string.attach_done, transfer.reference.orEmpty()), style = MaterialTheme.typography.bodySmall, fontFamily = UniTheme.type.identifierFamily, color = colors.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                    transfer.remoteError?.let { Text(stringResource(R.string.attach_remote_error, it), style = MaterialTheme.typography.labelSmall, color = colors.warning) }
                } else {
                    // Kept on the host, not where this SSH window's agent runs: shown and copyable, never pasted for the reader.
                    Text(stringResource(R.string.attach_kept_on_host, transfer.reference.orEmpty()), style = MaterialTheme.typography.bodySmall, fontFamily = UniTheme.type.identifierFamily, color = colors.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(transfer.remoteError?.let { stringResource(R.string.attach_remote_error_only, it) } ?: stringResource(R.string.attach_not_pasted_ssh), style = MaterialTheme.typography.labelSmall, color = colors.warning)
                    TextButton(onClick = { copyToClipboard(context, transfer.reference.orEmpty()) }, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                        Icon(Icons.Rounded.ContentCopy, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.attach_copy_host_path), style = MaterialTheme.typography.labelMedium)
                    }
                }
                AttachViewModel.Status.FAILED -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.ErrorOutline, null, Modifier.size(16.dp), tint = colors.danger)
                    Text(transfer.failure.attachMessage(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = colors.danger)
                    TextButton(onClick = onRetry, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                        Icon(Icons.Rounded.Refresh, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.upload_retry), style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
    }
}

/** The reason in the reader's words, from the host's code, the transport, or the file itself. */
@Composable
private fun Throwable?.attachMessage(): String = when (this) {
    is MachineFailure.Rejected -> when (code) {
        "too_large" -> stringResource(R.string.attach_failed_too_large)
        "locked" -> stringResource(R.string.attach_failed_locked)
        "io_failed" -> stringResource(R.string.attach_failed_io)
        "not_found" -> stringResource(R.string.attach_failed_not_found)
        else -> stringResource(R.string.attach_failed_rejected, detail?.takeIf { it.isNotBlank() } ?: code)
    }
    is MachineFailure -> stringResource(R.string.attach_failed_transport)
    is UploadFailure -> message()
    else -> stringResource(R.string.attach_failed_transport)
}
