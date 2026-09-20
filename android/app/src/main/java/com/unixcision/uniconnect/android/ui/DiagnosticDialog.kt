package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ConnectionEvent
import com.unixcision.uniconnect.android.domain.CrashReport
import com.unixcision.uniconnect.android.domain.DiagnosticEnvironment
import com.unixcision.uniconnect.android.domain.DiagnosticReport
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Enseña por qué falló la conexión, en vez de dejar a la persona adivinando.
 *
 * El informe se muestra **entero y tal cual se va a compartir**: lo que se lee aquí es exactamente
 * lo que sale por el botón de compartir, así que nadie tiene que fiarse de que la app mande lo que
 * dice. Se puede leer sin conexión, que es cuando hace falta.
 */
@Composable
fun DiagnosticDialog(
    environment: DiagnosticEnvironment?,
    events: List<ConnectionEvent>,
    crashes: List<CrashReport> = emptyList(),
    onShare: () -> Unit,
    onSend: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    // Se arma fuera de cualquier lectura del sistema: aquí ya está todo leído.
    val report = DiagnosticReport.render(environment, events, crashes = crashes)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.diagnostics_title)) },
        text = {
            Column(
                Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    DiagnosticReport.headline(events, crashes),
                    style = MaterialTheme.typography.bodyMedium,
                    color = UniTheme.colors.warning,
                )
                // Monoespaciada y con desplazamiento lateral: las columnas del historial solo se
                // leen si no se parten, y partirlas convierte una tabla en un muro.
                Text(
                    report,
                    Modifier.horizontalScroll(rememberScrollState()),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 10.sp,
                    color = UniTheme.colors.muted,
                )
            }
        },
        confirmButton = { TextButton(onClick = onShare) { Text(stringResource(R.string.diagnostics_share)) } },
        dismissButton = {
            Column {
                // Enviar solo se ofrece cuando hay a dónde: un botón que falla en el momento en que
                // se necesita es peor que no tenerlo, y este informe nace precisamente de no haber
                // conexión. Compartir siempre funciona.
                if (onSend != null) TextButton(onClick = onSend) { Text(stringResource(R.string.diagnostics_send)) }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.diagnostics_close)) }
            }
        },
        containerColor = UniTheme.colors.surface,
    )
}
