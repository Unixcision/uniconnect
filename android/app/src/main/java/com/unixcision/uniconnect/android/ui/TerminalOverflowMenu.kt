package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** Una acción del menú ⋮ del terminal: qué es y, si no es obvio, qué hace de verdad. */
data class TerminalMenuEntry(
    val icon: ImageVector,
    val title: String,
    val note: String? = null,
    val enabled: Boolean = true,
    val tint: Color? = null,
    val onClick: () -> Unit,
)

/**
 * Lo que no cabe en la barra, con nombre.
 *
 * La barra del terminal acumulaba un icono por cada función —favorito, vista, dos «refrescos»,
 * terminal real, informe— y en un móvil se apelotonaba. Peor: dos iconos casi iguales hacían cosas
 * distintas (uno pide la pantalla otra vez; otro rehace el enganche tmux en el equipo) y no había
 * forma de saberlo. Aquí cada acción lleva su nombre y, cuando hace falta, una línea que explica
 * qué toca.
 */
@Composable
fun TerminalOverflowMenu(entries: List<TerminalMenuEntry>) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Rounded.MoreVert, stringResource(R.string.terminal_more), tint = UniTheme.colors.muted)
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            modifier = Modifier.widthIn(max = 320.dp),
            containerColor = UniTheme.colors.surfaceRaised,
        ) {
            entries.forEach { entry ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(entry.title, style = MaterialTheme.typography.bodyMedium)
                            entry.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted) }
                        }
                    },
                    leadingIcon = { Icon(entry.icon, null, tint = entry.tint ?: UniTheme.colors.muted) },
                    enabled = entry.enabled,
                    onClick = { open = false; entry.onClick() },
                )
            }
        }
    }
}
