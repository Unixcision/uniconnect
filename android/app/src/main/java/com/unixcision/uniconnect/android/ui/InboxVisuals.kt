package com.unixcision.uniconnect.android.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.media.MediaMetadataRetriever
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AudioFile
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.InsertDriveFile
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** El icono de cada tipo, para la miniatura que aún no hay o que no puede haber. */
internal val InboxKind.icon: ImageVector
    get() = when (this) {
        InboxKind.IMAGE -> Icons.Rounded.Image
        InboxKind.VIDEO -> Icons.Rounded.Movie
        InboxKind.AUDIO -> Icons.Rounded.AudioFile
        InboxKind.DOCUMENT -> Icons.Rounded.Description
        InboxKind.OTHER -> Icons.Rounded.InsertDriveFile
    }

internal val InboxKind.label: Int
    get() = when (this) {
        InboxKind.IMAGE -> R.string.inbox_kind_image
        InboxKind.VIDEO -> R.string.inbox_kind_video
        InboxKind.AUDIO -> R.string.inbox_kind_audio
        InboxKind.DOCUMENT -> R.string.inbox_kind_document
        InboxKind.OTHER -> R.string.inbox_kind_other
    }

/** «12 archivos». */
@Composable
internal fun inboxFiles(count: Int): String = pluralStringResource(R.plurals.inbox_files, count, count)

/** Fecha y hora cortas de un instante del equipo (segundos desde época). */
internal fun inboxStamp(seconds: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT, Locale.getDefault()).format(Date(seconds * 1000))

/** Solo la fecha, para «desde el …». */
internal fun inboxDay(seconds: Long): String =
    DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.getDefault()).format(Date(seconds * 1000))

/** Por qué no se ha podido, con el nombre del equipo en la frase. */
@Composable
internal fun Throwable.inboxMessage(machineName: String): String = when (this) {
    is MachineFailure.Rejected -> when (code) {
        "approval_required", "unauthorized" -> stringResource(R.string.inbox_failed_approval, machineName)
        "locked" -> stringResource(R.string.inbox_failed_locked, machineName)
        "not_found" -> stringResource(R.string.inbox_failed_gone, machineName)
        else -> stringResource(R.string.inbox_failed_other, machineName, detail?.takeIf { it.isNotBlank() } ?: code)
    }
    else -> stringResource(R.string.inbox_failed_transport, machineName)
}

/**
 * La imagen de [file] reducida para caber en [maxSide] píxeles, o el primer fotograma si es un
 * vídeo. Se decodifica fuera del hilo principal; mientras tanto (o si no se puede) es `null`.
 */
@Composable
internal fun rememberInboxBitmap(file: File?, kind: InboxKind, maxSide: Int): State<ImageBitmap?> =
    produceState<ImageBitmap?>(null, file, kind, maxSide) {
        value = if (file == null) null else withContext(Dispatchers.IO) {
            runCatching {
                when (kind) {
                    InboxKind.IMAGE -> {
                        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                        BitmapFactory.decodeFile(file.path, bounds)
                        var sample = 1
                        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
                        BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
                    }
                    InboxKind.VIDEO -> MediaMetadataRetriever().run {
                        try {
                            setDataSource(file.path)
                            val frame = if (Build.VERSION.SDK_INT >= 27) {
                                getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, maxSide, maxSide)
                            } else {
                                getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)?.let { full ->
                                    val scale = maxSide.toFloat() / maxOf(full.width, full.height)
                                    if (scale >= 1f) full else Bitmap.createScaledBitmap(full, (full.width * scale).toInt().coerceAtLeast(1), (full.height * scale).toInt().coerceAtLeast(1), true)
                                }
                            }
                            frame?.asImageBitmap()
                        } finally {
                            release()
                        }
                    }
                    else -> null
                }
            }.getOrNull()
        }
    }
