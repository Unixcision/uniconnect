package com.unixcision.uniconnect.android.ui

import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * La miniatura de un archivo del propio móvil (lo que se acaba de adjuntar), sacada de su Uri
 * sin preguntar al equipo: fotos, vídeos y documentos que el sistema sepa pintar. Lo que no, el
 * icono de su tipo. Se decodifica fuera del hilo principal.
 */
@Composable
internal fun LocalThumbnail(uri: Uri, side: Dp = 52.dp) {
    val context = LocalContext.current
    val colors = UniTheme.colors
    val kind = remember(uri) { InboxKind.fromMime(runCatching { context.contentResolver.getType(uri) }.getOrNull()) }
    val pixels = with(androidx.compose.ui.platform.LocalDensity.current) { side.roundToPx() * 2 }
    val bitmap by produceState<ImageBitmap?>(null, uri) {
        value = withContext(Dispatchers.IO) {
            val resolver = context.contentResolver
            // El sistema sabe hacer miniaturas de fotos y vídeos del selector; la foto de la cámara
            // viene de nuestro propio FileProvider, que no las hace, y se decodifica a mano.
            (if (Build.VERSION.SDK_INT >= 29) runCatching { resolver.loadThumbnail(uri, Size(pixels, pixels), null) }.getOrNull() else null)?.asImageBitmap()
                ?: if (kind == InboxKind.IMAGE) runCatching {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                    var sample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= pixels) sample *= 2
                    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }?.asImageBitmap()
                }.getOrNull() else null
        }
    }
    Box(
        Modifier.size(side).clip(RoundedCornerShape(10.dp)).background(colors.surfaceRaised),
        contentAlignment = Alignment.Center,
    ) {
        val image = bitmap
        if (image != null) Image(image, null, Modifier.size(side), contentScale = ContentScale.Crop)
        else Icon(kind.icon, null, Modifier.size(side / 2), tint = colors.muted)
    }
}
