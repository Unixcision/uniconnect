package com.unixcision.uniconnect.android.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.background
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
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.OpenInNew
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Un adjunto de esta ventana en grande, sacado del propio móvil: la foto con zoom, el vídeo o el
 * audio sonando, o «Abrir con…» para lo demás. Si ya llegó, «Pegar otra vez» lo devuelve a la cajita.
 */
@Composable
internal fun LocalPreviewDialog(transfer: AttachViewModel.Transfer, onPasteAgain: ((String) -> Unit)?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val kind = remember(transfer.uri) { localKind(context, transfer.uri) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxWidth().padding(12.dp), shape = UniTheme.shapes.sheet, color = colors.surface) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(kind.icon, null, tint = colors.accent)
                    Column(Modifier.weight(1f)) {
                        Text(transfer.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, fontFamily = UniTheme.type.identifierFamily, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text("${stringResource(kind.label)} · ${formatSize(transfer.size)}", style = MaterialTheme.typography.labelSmall, color = colors.muted)
                    }
                    IconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, stringResource(R.string.close), tint = colors.muted) }
                }
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 140.dp).clip(UniTheme.shapes.card).background(colors.surfaceRaised),
                    contentAlignment = Alignment.Center,
                ) {
                    when (kind) {
                        InboxKind.IMAGE -> ZoomableImage(rememberUriBitmap(transfer.uri, kind, FULL_SIDE, thumbnail = false).value, transfer.name)
                        InboxKind.VIDEO, InboxKind.AUDIO -> InboxMediaPlayer(transfer.uri, audio = kind == InboxKind.AUDIO)
                        else -> Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            LocalThumbnail(transfer.uri, side = 96.dp)
                            OutlinedButton(onClick = {
                                val view = Intent(Intent.ACTION_VIEW).setDataAndType(transfer.uri, context.contentResolver.getType(transfer.uri) ?: "*/*")
                                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                try {
                                    context.startActivity(Intent.createChooser(view, context.getString(R.string.inbox_open_with)))
                                } catch (e: ActivityNotFoundException) {
                                    Toast.makeText(context, R.string.inbox_no_app, Toast.LENGTH_SHORT).show()
                                }
                            }, shape = UniTheme.shapes.button) {
                                Icon(Icons.Rounded.OpenInNew, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.inbox_open_with))
                            }
                        }
                    }
                }
                transfer.reference?.let { reference ->
                    Text(reference, style = MaterialTheme.typography.labelSmall, fontFamily = UniTheme.type.identifierFamily, color = colors.muted)
                    if (onPasteAgain != null) Button(onClick = { onPasteAgain(reference) }, Modifier.fillMaxWidth(), shape = UniTheme.shapes.button) {
                        Icon(Icons.Rounded.ContentPaste, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.attach_paste_again), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}
