package com.unixcision.uniconnect.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AttachFile
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Share
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
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadResult
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
import com.unixcision.uniconnect.android.ui.components.ActionTile
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * "Enviar archivos": take a photo or pick images or files, watch them go up one by one, and copy
 * or share the link each one comes back with. The service they go to is chosen at the top and
 * kept with the other settings, because these services go down and the reader must be able to
 * move to another without a new build.
 *
 * No permission is declared for any of this: the photo picker and the document picker hand over
 * grants of their own, and a camera app does the shooting through a file this app provides.
 */
@Composable
fun UploadScreen(model: UploadViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val spacing = UniTheme.spacing
    var localError by remember { mutableStateOf<Int?>(null) }
    val pickers = rememberAttachmentPickers(onPicked = model::enqueue, onUnavailable = { localError = it })
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = spacing.page, end = spacing.page, top = 8.dp, bottom = 40.dp),
        verticalArrangement = Arrangement.spacedBy(spacing.gap),
    ) {
        item { ServicePicker(state.service, onChange = model::setService) }
        item {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
                ActionTile(Icons.Rounded.CameraAlt, stringResource(R.string.upload_take_photo), Modifier.weight(1f), pickers.takePhoto)
                ActionTile(Icons.Rounded.Image, stringResource(R.string.upload_pick_images), Modifier.weight(1f), pickers.pickImages)
                ActionTile(Icons.Rounded.AttachFile, stringResource(R.string.upload_pick_files), Modifier.weight(1f), pickers.pickFiles)
            }
        }
        localError?.let { message -> item { ErrorNotice(message) { localError = null } } }
        if (state.uploads.isNotEmpty()) {
            item { SectionLabel(stringResource(R.string.upload_uploads)) { Text("${state.uploads.size}", style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted) } }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(UniTheme.layout.rowGap(spacing))) {
                    state.uploads.asReversed().forEach { upload ->
                        key(upload.id) { UploadRow(upload, onRetry = { model.retry(upload.id) }, onDismiss = { model.dismiss(upload.id) }) }
                    }
                }
            }
        }
        item { SectionLabel(stringResource(R.string.upload_history)) { Text("${state.history.size}", style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.muted) } }
        if (state.history.isEmpty()) item { Text(stringResource(R.string.upload_empty), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall) }
        else item {
            Column(verticalArrangement = Arrangement.spacedBy(UniTheme.layout.rowGap(spacing))) {
                state.history.forEach { result -> key(result.link) { HistoryRow(result) { model.removeFromHistory(result.link) } } }
            }
        }
        item { Text(stringResource(R.string.upload_public_note), Modifier.padding(top = 8.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall) }
    }
}

/**
 * The service files go to: the measured presets as chips plus a custom one with its own domain
 * and style. Choosing stores at once; the custom form stores when saved.
 */
@Composable
private fun ServicePicker(service: UploadService, onChange: (UploadService) -> Unit) {
    var editing by rememberSaveable { mutableStateOf(false) }
    val custom = !service.isPreset
    var domain by rememberSaveable(service) { mutableStateOf(if (custom) service.domain else "") }
    var style by rememberSaveable(service) { mutableStateOf(if (custom) service.style else UploadStyle.RAW_NAMED) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel(stringResource(R.string.upload_service))
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            UploadService.presets.forEach { preset ->
                ServiceChip(preset.domain, selected = !editing && service == preset) { editing = false; onChange(preset) }
            }
            ServiceChip(stringResource(R.string.upload_custom), selected = editing || custom) { editing = true }
        }
        Text(stringResource(R.string.upload_service_note, service.baseUrl), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
        if (editing || custom) GlassCard(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SheetField(domain, { domain = it }, stringResource(R.string.upload_domain), hint = stringResource(R.string.upload_domain_hint), monospace = true)
                Text(stringResource(R.string.upload_style), style = MaterialTheme.typography.bodyMedium)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    UploadStyle.entries.forEachIndexed { index, candidate ->
                        SegmentedButton(
                            selected = style == candidate, onClick = { style = candidate },
                            shape = SegmentedButtonDefaults.itemShape(index, UploadStyle.entries.size),
                            colors = SegmentedButtonDefaults.colors(
                                activeContainerColor = UniTheme.colors.accentSoft, activeContentColor = UniTheme.colors.accent,
                                activeBorderColor = UniTheme.colors.accent.copy(alpha = .5f), inactiveContentColor = UniTheme.colors.muted,
                                inactiveBorderColor = UniTheme.colors.outline,
                            ),
                        ) { Text(stringResource(candidate.label), style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                }
                val normalized = UploadService.normalizeDomain(domain)
                Button(
                    onClick = { onChange(UploadService(normalized, style)); editing = false },
                    enabled = normalized.isNotEmpty(), modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button,
                ) { Text(stringResource(R.string.upload_save_service), fontWeight = FontWeight.SemiBold) }
            }
        }
    }
}

@Composable
internal fun ServiceChip(label: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(
        selected = selected, onClick = onClick,
        label = { Text(label, style = MaterialTheme.typography.labelMedium, fontFamily = UniTheme.type.identifierFamily) },
        shape = UniTheme.shapes.chip,
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = UniTheme.colors.accentSoft, selectedLabelColor = UniTheme.colors.accent,
            containerColor = UniTheme.colors.surface, labelColor = UniTheme.colors.muted,
        ),
        border = FilterChipDefaults.filterChipBorder(enabled = true, selected = selected, borderColor = UniTheme.colors.outline, selectedBorderColor = UniTheme.colors.accent.copy(alpha = .5f)),
    )
}

/** A picked file on its way: queued, a progress bar, the link with copy and share, or why it failed. */
@Composable
private fun UploadRow(upload: UploadViewModel.Upload, onRetry: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val accent = when (upload.status) {
        UploadViewModel.Status.DONE -> colors.success
        UploadViewModel.Status.FAILED -> colors.danger
        UploadViewModel.Status.UPLOADING -> colors.accent
        UploadViewModel.Status.PENDING -> null
    }
    GlassCard(Modifier.fillMaxWidth(), style = UniTheme.layout.rowsAs, accent = accent) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = UniTheme.layout.rowPadding), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(upload.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(formatSize(upload.size), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                if (upload.status != UploadViewModel.Status.UPLOADING) IconButton(onClick = onDismiss, Modifier.size(28.dp)) {
                    Icon(Icons.Rounded.Close, stringResource(R.string.upload_remove), Modifier.size(16.dp), tint = colors.muted)
                }
            }
            when (upload.status) {
                UploadViewModel.Status.PENDING -> Text(stringResource(R.string.upload_queued), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                UploadViewModel.Status.UPLOADING -> {
                    LinearProgressIndicator(progress = { upload.fraction }, modifier = Modifier.fillMaxWidth(), color = colors.accent, trackColor = colors.surfaceRaised)
                    Text(stringResource(R.string.upload_uploading, (upload.fraction * 100).toInt()), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                }
                UploadViewModel.Status.DONE -> LinkLine(upload.link.orEmpty(), context)
                UploadViewModel.Status.FAILED -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Rounded.ErrorOutline, null, Modifier.size(16.dp), tint = colors.danger)
                    Text(upload.failure?.message() ?: stringResource(R.string.upload_no_link), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = colors.danger)
                    TextButton(onClick = onRetry, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                        Icon(Icons.Rounded.Refresh, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp)); Text(stringResource(R.string.upload_retry), style = MaterialTheme.typography.labelMedium)
                    }
                }
            }
        }
    }
}

/** A link kept from before: the link itself, what it was, and copy, share and forget. */
@Composable
private fun HistoryRow(result: UploadResult, onDelete: () -> Unit) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val stamp = remember(result.uploadedAt) { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT, Locale.getDefault()).format(Date(result.uploadedAt)) }
    GlassCard(Modifier.fillMaxWidth(), style = UniTheme.layout.rowsAs) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = UniTheme.layout.rowPadding), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(result.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${formatSize(result.size)} · $stamp", style = MaterialTheme.typography.labelSmall, color = colors.muted, maxLines = 1)
                IconButton(onClick = onDelete, Modifier.size(28.dp)) { Icon(Icons.Rounded.DeleteOutline, stringResource(R.string.upload_delete), Modifier.size(16.dp), tint = colors.muted) }
            }
            LinkLine(result.link, context)
        }
    }
}

/** The link, selectable by tap to copy, with copy and share beside it. */
@Composable
private fun LinkLine(link: String, context: Context) {
    val colors = UniTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(Icons.Rounded.Link, null, Modifier.size(16.dp), tint = colors.accent)
        Text(link, Modifier.weight(1f).clickable { copyToClipboard(context, link) }, style = MaterialTheme.typography.bodySmall, fontFamily = UniTheme.type.identifierFamily, color = colors.accent, maxLines = 2, overflow = TextOverflow.Ellipsis)
        IconButton(onClick = { copyToClipboard(context, link) }, Modifier.size(32.dp)) { Icon(Icons.Rounded.ContentCopy, stringResource(R.string.upload_copy), Modifier.size(18.dp), tint = colors.accent) }
        IconButton(onClick = { shareLink(context, link) }, Modifier.size(32.dp)) { Icon(Icons.Rounded.Share, stringResource(R.string.upload_share), Modifier.size(18.dp), tint = colors.muted) }
    }
}

/** The reason in the reader's words, with the domain or file in the sentence. */
@Composable
internal fun UploadFailure.message(): String = when (this) {
    is UploadFailure.Unreachable -> stringResource(R.string.upload_unreachable, domain)
    is UploadFailure.Rejected -> stringResource(R.string.upload_rejected, domain, code)
    is UploadFailure.NoLink -> stringResource(R.string.upload_no_link)
    is UploadFailure.Unreadable -> stringResource(R.string.upload_unreadable, name)
}

private val UploadStyle.label: Int
    get() = when (this) {
        UploadStyle.RAW_NAMED -> R.string.upload_style_raw
        UploadStyle.MULTIPART_FILE -> R.string.upload_style_multipart
        UploadStyle.LITTERBOX -> R.string.upload_style_litterbox
    }

internal fun copyToClipboard(context: Context, text: String) {
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("UniConnect", text))
    // Android 13 and later shows its own confirmation when something is copied.
    if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, R.string.upload_copied, Toast.LENGTH_SHORT).show()
}

private fun shareLink(context: Context, link: String) {
    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link)
    runCatching { context.startActivity(Intent.createChooser(send, context.getString(R.string.upload_share))) }
}

/** Bytes as the reader says them: B, KB, MB or GB with one decimal past kilobytes. */
internal fun formatSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(Locale.getDefault(), "%.1f KB", bytes / 1024.0)
    bytes < 1024L * 1024 * 1024 -> String.format(Locale.getDefault(), "%.1f MB", bytes / (1024.0 * 1024))
    else -> String.format(Locale.getDefault(), "%.2f GB", bytes / (1024.0 * 1024 * 1024))
}
