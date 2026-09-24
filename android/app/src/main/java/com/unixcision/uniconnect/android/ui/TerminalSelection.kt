package com.unixcision.uniconnect.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.TerminalFreeze
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * Mantener pulsado el terminal abre la selección.
 *
 * Mira el dedo en el paso inicial, antes que el scroll y el zoom del lienzo, y **no consume nada**
 * mientras dura la espera: si el dedo se mueve más allá del umbral, o entra un segundo dedo, el
 * gesto es de quien lo estaba esperando y esto no hace nada. Solo un dedo quieto el tiempo de una
 * pulsación larga cuenta, y entonces se queda con el resto del gesto para que soltar no arrastre.
 */
fun Modifier.selectOnLongPress(onSelect: () -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        val slop = viewConfiguration.touchSlop
        var quieto = true
        val esperaCortada = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                val change = event.changes.firstOrNull { it.id == down.id }
                if (change == null || !change.pressed || event.changes.size > 1 ||
                    (change.position - down.position).getDistance() > slop
                ) { quieto = false; break }
            }
        }
        if (esperaCortada == null && quieto) {
            onSelect()
            do {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                event.changes.forEach { it.consume() }
            } while (event.changes.any { it.pressed })
        }
    }
}

/**
 * La pantalla como texto que se puede seleccionar con los tiradores de Android.
 *
 * Es el camino que no depende de nada del otro lado —ni de tmux, ni de que el programa copie—:
 * lo que se ve, se puede copiar. Trabaja sobre una **foto** de la pantalla sacada al abrir
 * (``TerminalFreeze``), no sobre la pantalla viva: si la IA sigue escribiendo, lo que se está
 * seleccionando no se mueve. «Actualizar» saca otra foto de lo que haya en ese momento.
 *
 * [current] lee la pantalla de ahora; se llama al abrir y al pulsar «Actualizar», nunca sola.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalSelectionSheet(current: () -> TerminalSnapshot?, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val latest by rememberUpdatedState(current)
    val freeze = remember { TerminalFreeze({ latest() }, System::currentTimeMillis) }
    var photo by remember { mutableStateOf(freeze.take()) }
    val texto = photo?.text.orEmpty()
    val hora = remember(photo?.takenAt) {
        photo?.takenAt?.let { DateFormat.getTimeInstance(DateFormat.MEDIUM, Locale.getDefault()).format(Date(it)) }.orEmpty()
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = UniTheme.colors.surface,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp).navigationBarsPadding().padding(bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.terminal_select_title), style = MaterialTheme.typography.titleMedium)
                    if (hora.isNotEmpty()) Text(stringResource(R.string.terminal_select_frozen_at, hora), color = UniTheme.colors.accent, style = MaterialTheme.typography.labelMedium)
                }
                TextButton(onClick = { photo = freeze.take() }) {
                    Icon(Icons.Rounded.Refresh, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.terminal_select_refresh))
                }
            }
            Text(stringResource(R.string.terminal_select_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
            // La clave es la foto: al actualizar, la selección vieja no se queda sobre texto nuevo.
            key(photo?.takenAt) {
                SelectionContainer(
                    Modifier.fillMaxWidth().heightIn(max = 440.dp)
                        .verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()),
                ) {
                    Text(texto, fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp, color = UniTheme.colors.text)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.diagnostics_close)) }
                Spacer(Modifier.width(8.dp))
                Button(onClick = { copiar(context, texto); onDismiss() }, enabled = texto.isNotEmpty(), shape = UniTheme.shapes.button) {
                    Icon(Icons.Rounded.ContentCopy, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.terminal_select_copy_all))
                }
            }
        }
    }
}

private fun copiar(context: Context, texto: String) {
    runCatching {
        val manager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        manager.setPrimaryClip(ClipData.newPlainText("UniConnect", texto))
        // Android 13+ ya confirma con su propio aviso; antes no hay nada, y copiar a ciegas confunde.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(context, R.string.terminal_select_copied, Toast.LENGTH_SHORT).show()
        }
    }
}
