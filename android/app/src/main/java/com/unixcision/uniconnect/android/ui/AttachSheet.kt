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
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.ui.components.ActionTile
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The clip in a terminal's bar. Opens the quick sheet to attach, and, sheet open or closed,
 * pastes into this window's composer whatever its transfers come back with, exactly once each.
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
        val ready = mine.filter { it.status == AttachViewModel.Status.DONE && !it.pasted && it.reference != null }
        if (ready.isEmpty()) return@LaunchedEffect
        // Fold locally: the draft the screen holds only catches up after the change is applied.
        var text = latestDraft
        ready.forEach { transfer ->
            text = AttachPaste.pasteInto(text, requireNotNull(transfer.reference))
            model.markPasted(transfer.id)
        }
        latestChange(text)
        Toast.makeText(context, if (ready.any { it.isLink }) R.string.attach_pasted_link else R.string.attach_pasted_path, Toast.LENGTH_SHORT).show()
    }
    val busy = mine.any { it.status == AttachViewModel.Status.SENDING || it.status == AttachViewModel.Status.PENDING }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Rounded.AttachFile, stringResource(R.string.attach_title), tint = if (busy) UniTheme.colors.accent else UniTheme.colors.muted)
    }
    if (open) AttachSheet(model, target, mine, state.service, onDismiss = { open = false })
}

/** Quick sheet: three ways to pick, the transfers of this window, and where they go. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttachSheet(model: AttachViewModel, target: AttachTarget, transfers: List<AttachViewModel.Transfer>, service: UploadService, onDismiss: () -> Unit) {
    var localError by remember { mutableStateOf<Int?>(null) }
    val pickers = rememberAttachmentPickers(onPicked = { model.attach(target, it) }, onUnavailable = { localError = it })
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
                note = if (target.supportsFilePut) stringResource(R.string.attach_note_host, target.machine.name)
                else stringResource(R.string.attach_note_fallback, target.machine.name, service.baseUrl),
                tone = UniTheme.colors.accent,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(UniTheme.spacing.gapSmall)) {
                ActionTile(Icons.Rounded.CameraAlt, stringResource(R.string.upload_take_photo), Modifier.weight(1f), pickers.takePhoto)
                ActionTile(Icons.Rounded.Image, stringResource(R.string.upload_pick_images), Modifier.weight(1f), pickers.pickImages)
                ActionTile(Icons.Rounded.AttachFile, stringResource(R.string.upload_pick_files), Modifier.weight(1f), pickers.pickFiles)
            }
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

/** One attachment: queued, a progress bar, the pasted reference, or why it failed. */
@Composable
private fun TransferRow(transfer: AttachViewModel.Transfer, onRetry: () -> Unit, onDismiss: () -> Unit) {
    val colors = UniTheme.colors
    val accent = when (transfer.status) {
        AttachViewModel.Status.DONE -> colors.success
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
                AttachViewModel.Status.DONE -> {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Rounded.Check, null, Modifier.size(16.dp), tint = colors.success)
                        Text(stringResource(R.string.attach_done, transfer.reference.orEmpty()), style = MaterialTheme.typography.bodySmall, fontFamily = UniTheme.type.identifierFamily, color = colors.text, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                    transfer.remoteError?.let { Text(stringResource(R.string.attach_remote_error, it), style = MaterialTheme.typography.labelSmall, color = colors.warning) }
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
