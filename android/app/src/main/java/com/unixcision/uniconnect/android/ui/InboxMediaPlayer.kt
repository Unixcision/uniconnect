package com.unixcision.uniconnect.android.ui

import android.widget.VideoView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AudioFile
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import kotlinx.coroutines.delay
import java.io.File
import java.util.Locale

/**
 * Reproduce un vídeo o un audio ya traído al móvil, con play/pausa y barra para moverse. Un
 * audio no tiene imagen: se enseña su icono y el reproductor queda reducido a los controles.
 */
@Composable
internal fun InboxMediaPlayer(file: File, audio: Boolean) {
    val colors = UniTheme.colors
    var player by remember { mutableStateOf<VideoView?>(null) }
    var playing by remember { mutableStateOf(false) }
    var duration by remember { mutableIntStateOf(0) }
    var position by remember { mutableIntStateOf(0) }
    var aspect by remember { mutableFloatStateOf(16f / 9f) }
    var seeking by remember { mutableStateOf<Float?>(null) }
    // La barra sigue al reproductor mientras suena; VideoView no avisa de su posición, se le pregunta.
    LaunchedEffect(player, playing) {
        while (playing) {
            player?.let { position = it.currentPosition }
            delay(250)
        }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (audio) Icon(Icons.Rounded.AudioFile, null, Modifier.padding(top = 16.dp).size(72.dp), tint = colors.accent)
        AndroidView(
            factory = { context ->
                VideoView(context).apply {
                    setOnPreparedListener { media ->
                        duration = media.duration.coerceAtLeast(0)
                        if (media.videoWidth > 0 && media.videoHeight > 0) aspect = media.videoWidth.toFloat() / media.videoHeight
                        start()
                        playing = true
                    }
                    setOnCompletionListener { playing = false; position = duration }
                    setOnErrorListener { _, _, _ -> playing = false; false }
                    setVideoPath(file.path)
                    player = this
                }
            },
            onRelease = { it.stopPlayback() },
            // Un vídeo vertical a todo lo ancho taparía los botones: se limita el alto y se ajusta el ancho.
            modifier = if (audio) Modifier.fillMaxWidth().height(1.dp)
            else Modifier.heightIn(max = 420.dp).aspectRatio(aspect, matchHeightConstraintsFirst = aspect < 1f),
        )
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = {
                val view = player ?: return@IconButton
                if (view.isPlaying) { view.pause(); playing = false } else { view.start(); playing = true }
            }) {
                Icon(
                    if (playing) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                    stringResource(if (playing) R.string.inbox_pause else R.string.inbox_play),
                    tint = colors.accent,
                )
            }
            Slider(
                value = seeking ?: if (duration > 0) position.toFloat() / duration else 0f,
                onValueChange = { seeking = it },
                onValueChangeFinished = {
                    seeking?.let { fraction -> player?.seekTo((fraction * duration).toInt()); position = (fraction * duration).toInt() }
                    seeking = null
                },
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(thumbColor = colors.accent, activeTrackColor = colors.accent, inactiveTrackColor = colors.outline),
            )
            Text("${clock(position)} / ${clock(duration)}", Modifier.padding(start = 8.dp), style = MaterialTheme.typography.labelSmall, color = colors.muted)
        }
    }
}

private fun clock(millis: Int): String {
    val seconds = millis / 1000
    return if (seconds >= 3600) String.format(Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    else String.format(Locale.ROOT, "%d:%02d", seconds / 60, seconds % 60)
}
