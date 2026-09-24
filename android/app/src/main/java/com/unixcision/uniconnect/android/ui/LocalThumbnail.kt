package com.unixcision.uniconnect.android.ui

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * La miniatura de un archivo del propio móvil (lo que se acaba de adjuntar), sacada de su Uri
 * sin preguntar al equipo: fotos, vídeos y documentos que el sistema sepa pintar. Lo que no, el
 * icono de su tipo. Con [onClick] se puede tocar para verlo en grande.
 */
@Composable
internal fun LocalThumbnail(uri: Uri, side: Dp = 52.dp, onClick: (() -> Unit)? = null) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val kind = remember(uri) { localKind(context, uri) }
    val pixels = with(LocalDensity.current) { side.roundToPx() * 2 }
    val bitmap by rememberUriBitmap(uri, kind, pixels, thumbnail = true)
    Box(
        Modifier.size(side).clip(RoundedCornerShape(10.dp)).background(colors.surfaceRaised)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        val image = bitmap
        if (image != null) Image(image, null, Modifier.size(side), contentScale = ContentScale.Crop)
        else Icon(kind.icon, null, Modifier.size(side / 2), tint = colors.muted)
        if (kind == InboxKind.VIDEO || kind == InboxKind.AUDIO) {
            Icon(
                Icons.Rounded.PlayArrow, null,
                Modifier.align(Alignment.Center).size(side / 2.4f).clip(CircleShape).background(colors.background.copy(alpha = .65f)).padding(2.dp),
                tint = colors.text,
            )
        }
    }
}

/** El tipo de un archivo del móvil, por el MIME que da su proveedor. */
internal fun localKind(context: Context, uri: Uri): InboxKind =
    InboxKind.fromMime(runCatching { context.contentResolver.getType(uri) }.getOrNull())

/**
 * La imagen de [uri] reducida a [maxSide] píxeles, fuera del hilo principal. Con [thumbnail] se
 * prefiere la miniatura que ya tiene el sistema (vale también para vídeos y algunos documentos);
 * la foto de la cámara viene de nuestro propio FileProvider, que no las hace, y se decodifica a mano.
 */
@Composable
internal fun rememberUriBitmap(uri: Uri, kind: InboxKind, maxSide: Int, thumbnail: Boolean): State<ImageBitmap?> {
    val context = LocalContext.current
    return produceState<ImageBitmap?>(null, uri, maxSide, thumbnail) {
        value = withContext(Dispatchers.IO) {
            val resolver = context.contentResolver
            val system = if (thumbnail && Build.VERSION.SDK_INT >= 29) {
                runCatching { resolver.loadThumbnail(uri, Size(maxSide, maxSide), null) }.getOrNull()
            } else null
            system?.asImageBitmap() ?: if (kind == InboxKind.IMAGE) runCatching {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }?.asImageBitmap()
            }.getOrNull() else null
        }
    }
}
