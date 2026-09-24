package com.unixcision.uniconnect.android.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.io.File

/**
 * Un archivo de la bandeja abierto: la imagen (con zoom), el vídeo o el audio sonando, o un
 * documento para abrir con otra app. Debajo, lo que se vino a hacer: pegarlo otra vez en la
 * cajita (o copiar la ruta, en una ventana SSH) y, con doble confirmación, borrarlo del equipo.
 */
@Composable
internal fun InboxPreviewDialog(
    inbox: InboxViewModel,
    machine: Machine,
    entry: InboxEntry,
    pasteable: Boolean,
    onPaste: () -> Unit,
    onDismiss: () -> Unit,
) {
    val state by inbox.state.collectAsStateWithLifecycle()
    val preview = inbox.previewOf(state, machine, entry)
    val context = LocalContext.current
    val colors = UniTheme.colors
    var confirmDelete by remember { mutableStateOf(false) }
    // Lo que se mira dentro del móvil se trae al abrir; un documento, solo si se pide.
    LaunchedEffect(entry) { if (entry.kind.previewable) inbox.preview(machine, entry) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().padding(12.dp), shape = UniTheme.shapes.sheet, color = colors.surface) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(entry.kind.icon, null, tint = colors.accent)
                    Column(Modifier.weight(1f)) {
                        Text(entry.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = UniTheme.type.identifierFamily, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(
                            stringResource(R.string.inbox_meta, "${stringResource(entry.kind.label)} · ${formatSize(entry.size)}", inboxStamp(entry.modified)),
                            style = MaterialTheme.typography.labelSmall, color = colors.muted,
                        )
                    }
                    IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.close), tint = colors.muted) }
                }
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 140.dp).clip(UniTheme.shapes.card).background(colors.surfaceRaised),
                    contentAlignment = Alignment.Center,
                ) {
                    val file = preview?.file
                    val failure = preview?.failure
                    when {
                        failure != null -> Text(failure.inboxMessage(machine.name), Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = colors.danger)
                        file == null && preview != null -> Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            LinearProgressIndicator(
                                progress = { if (entry.size > 0) (preview.received.toFloat() / entry.size).coerceIn(0f, 1f) else 0f },
                                modifier = Modifier.fillMaxWidth(), color = colors.accent, trackColor = colors.outline,
                            )
                            Text(stringResource(R.string.inbox_downloading, formatSize(preview.received), formatSize(entry.size)), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                        }
                        file != null && entry.kind == InboxKind.IMAGE -> ZoomableImage(rememberInboxBitmap(file, InboxKind.IMAGE, FULL_SIDE).value, entry.name)
                        file != null && (entry.kind == InboxKind.VIDEO || entry.kind == InboxKind.AUDIO) -> InboxMediaPlayer(Uri.fromFile(file), audio = entry.kind == InboxKind.AUDIO)
                        else -> Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(entry.kind.icon, null, Modifier.size(56.dp), tint = colors.muted)
                            if (file == null) {
                                OutlinedButton(onClick = { inbox.preview(machine, entry) }, shape = UniTheme.shapes.button) {
                                    Icon(Icons.Rounded.Download, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.inbox_download_to_open))
                                }
                            } else {
                                OutlinedButton(onClick = { openWith(context, file) }, shape = UniTheme.shapes.button) {
                                    Icon(Icons.Rounded.OpenInNew, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.inbox_open_with))
                                }
                            }
                        }
                    }
                }
                SelectionContainer {
                    Text(entry.absolute, style = MaterialTheme.typography.labelSmall, fontFamily = UniTheme.type.identifierFamily, color = colors.muted)
                }
                if (!pasteable) Text(stringResource(R.string.inbox_not_pasted_ssh, machine.name), style = MaterialTheme.typography.labelSmall, color = colors.warning)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (pasteable) {
                        Button(onClick = onPaste, Modifier.weight(1f), shape = UniTheme.shapes.button) {
                            Icon(Icons.Rounded.ContentPaste, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.inbox_paste), fontWeight = FontWeight.SemiBold)
                        }
                    } else {
                        Button(onClick = { copyToClipboard(context, entry.absolute) }, Modifier.weight(1f), shape = UniTheme.shapes.button) {
                            Icon(Icons.Rounded.ContentCopy, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.inbox_copy_path), fontWeight = FontWeight.SemiBold)
                        }
                    }
                    val file = preview?.file
                    if (file != null && entry.kind.previewable) {
                        IconButton(onClick = { openWith(context, file) }) { Icon(Icons.Rounded.OpenInNew, stringResource(R.string.inbox_open_with), tint = colors.muted) }
                    }
                }
                TextButton(
                    onClick = {
                        if (confirmDelete) {
                            inbox.delete(machine, InboxDeletion(paths = listOf(entry.path)))
                            Toast.makeText(context, context.getString(R.string.inbox_deleted_one, machine.name), Toast.LENGTH_SHORT).show()
                            onDismiss()
                        } else {
                            confirmDelete = true
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                ) {
                    Icon(Icons.Rounded.DeleteOutline, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp))
                    Text(stringResource(if (confirmDelete) R.string.inbox_delete_one_confirm else R.string.inbox_delete_one))
                }
            }
        }
    }
}

/** La imagen entera, que se amplía y se mueve con dos dedos; mientras se decodifica, un indicador. */
@Composable
internal fun ZoomableImage(bitmap: ImageBitmap?, description: String) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val transform = rememberTransformableState { zoom, pan, _ ->
        scale = (scale * zoom).coerceIn(1f, 6f)
        offset = if (scale == 1f) Offset.Zero else offset + pan
    }
    val image = bitmap
    if (image == null) {
        CircularProgressIndicator(Modifier.padding(32.dp), color = UniTheme.colors.accent)
    } else {
        Image(
            image, description,
            Modifier.fillMaxWidth().heightIn(max = 520.dp).transformable(transform)
                .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
            contentScale = ContentScale.Fit,
        )
    }
}

/** Abre [file] con la app del móvil que lo sepa abrir, por su extensión. */
private fun openWith(context: Context, file: File) {
    val uri = runCatching { FileProvider.getUriForFile(context, "${context.packageName}.files", file) }.getOrNull() ?: return
    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "*/*"
    val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        context.startActivity(Intent.createChooser(view, context.getString(R.string.inbox_open_with)))
    } catch (e: ActivityNotFoundException) {
        Toast.makeText(context, R.string.inbox_no_app, Toast.LENGTH_SHORT).show()
    }
}

internal const val FULL_SIDE = 2048
