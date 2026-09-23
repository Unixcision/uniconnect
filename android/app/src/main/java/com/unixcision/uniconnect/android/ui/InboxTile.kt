package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxEntry
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.InboxPreviewRule
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Un archivo de la bandeja en la cuadrícula: su miniatura (o el icono de su tipo), nombre y
 * tamaño, y en la esquina el atajo para volver a pegarlo (o copiarlo, si pegar no sirve aquí).
 */
@Composable
internal fun InboxTile(
    inbox: InboxViewModel,
    state: InboxViewModel.State,
    machine: Machine,
    entry: InboxEntry,
    pasteable: Boolean,
    modifier: Modifier,
    onOpen: () -> Unit,
    onPaste: () -> Unit,
) {
    val colors = UniTheme.colors
    val context = LocalContext.current
    val preview = inbox.previewOf(state, machine, entry)
    LaunchedEffect(entry) { if (InboxPreviewRule.thumbnailOnSight(entry)) inbox.preview(machine, entry) }
    val thumbnail by rememberInboxBitmap(preview?.file, entry.kind, THUMBNAIL_SIDE)
    val corner = RoundedCornerShape(UniTheme.shapes.cardRadius)
    Column(modifier.clip(corner).background(colors.surfaceRaised).clickable(onClick = onOpen)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).background(colors.surface), contentAlignment = Alignment.Center) {
            val image = thumbnail
            if (image != null) {
                Image(image, entry.name, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                Icon(entry.kind.icon, stringResource(entry.kind.label), Modifier.size(34.dp), tint = colors.muted)
            }
            if (entry.kind == InboxKind.VIDEO || entry.kind == InboxKind.AUDIO) {
                Icon(
                    Icons.Rounded.PlayArrow, null,
                    Modifier.align(Alignment.BottomStart).padding(6.dp).size(24.dp).clip(CircleShape).background(colors.background.copy(alpha = .7f)).padding(3.dp),
                    tint = colors.text,
                )
            }
            Icon(
                if (pasteable) Icons.Rounded.ContentPaste else Icons.Rounded.ContentCopy,
                stringResource(if (pasteable) R.string.inbox_paste else R.string.inbox_copy_path),
                Modifier.align(Alignment.TopEnd).padding(5.dp).size(32.dp).clip(CircleShape)
                    .background(colors.surface.copy(alpha = .88f))
                    .clickable { if (pasteable) onPaste() else copyToClipboard(context, entry.absolute) }
                    .padding(7.dp),
                tint = colors.accent,
            )
        }
        Text(
            entry.name, Modifier.padding(start = 8.dp, end = 8.dp, top = 6.dp),
            style = MaterialTheme.typography.labelSmall, fontFamily = UniTheme.type.identifierFamily, color = colors.text,
            maxLines = 1, overflow = TextOverflow.MiddleEllipsis,
        )
        Text(formatSize(entry.size), Modifier.padding(start = 8.dp, end = 8.dp, bottom = 6.dp), style = MaterialTheme.typography.labelSmall, color = colors.muted, maxLines = 1)
    }
}

private const val THUMBNAIL_SIDE = 320
