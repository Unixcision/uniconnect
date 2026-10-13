package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CleaningServices
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DictationRetention
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Ajustes › Dictados: cuánto ocupa el historial de dictados y cómo liberar espacio, todo en la
 * propia sección (sin ventana emergente): por antigüedad, solo el audio o el dictado entero.
 */
@Composable
internal fun ColumnScope.DictationSettingsSection(history: DictationHistoryViewModel) {
    val records by history.records.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    var days by remember { mutableStateOf<Int?>(7) }
    var audioOnly by remember { mutableStateOf(true) }
    val now = remember(records) { System.currentTimeMillis() }
    val chosen = DictationRetention.olderThan(records, now, days?.let { it * DictationRetention.DAY_MILLIS })
        .let { list -> if (audioOnly) list.filter { it.audioPath != null } else list }
    val freed = DictationRetention.audioBytes(chosen)

    Text(stringResource(R.string.settings_dictations_note), color = colors.muted, style = MaterialTheme.typography.bodySmall)
    Text(
        stringResource(R.string.dictation_history_note, records.size, formatSize(DictationRetention.audioBytes(records))),
        Modifier.padding(top = 6.dp), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
    )
    if (records.isEmpty()) return

    Text(stringResource(R.string.dictation_cleanup_age), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelLarge, color = colors.muted)
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf(1 to R.string.inbox_cleanup_day, 7 to R.string.inbox_cleanup_week, 30 to R.string.inbox_cleanup_month).forEach { (value, label) ->
            ServiceChip(stringResource(label), selected = days == value) { days = value }
        }
        ServiceChip(stringResource(R.string.dictation_cleanup_all_ages), selected = days == null) { days = null }
    }
    Text(stringResource(R.string.dictation_cleanup_what), style = MaterialTheme.typography.labelLarge, color = colors.muted)
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ServiceChip(stringResource(R.string.dictation_cleanup_audio_only), selected = audioOnly) { audioOnly = true }
        ServiceChip(stringResource(R.string.dictation_cleanup_everything), selected = !audioOnly) { audioOnly = false }
    }
    Text(
        when {
            chosen.isEmpty() -> stringResource(R.string.dictation_cleanup_nothing)
            audioOnly -> stringResource(R.string.dictation_cleanup_estimate_audio, chosen.size, formatSize(freed))
            else -> stringResource(R.string.dictation_cleanup_estimate_all, chosen.size, formatSize(freed))
        },
        style = MaterialTheme.typography.bodySmall, color = colors.text,
    )
    TextButton(
        onClick = {
            val ids = chosen.mapTo(mutableSetOf()) { it.id }
            if (audioOnly) history.deleteAudio(ids) else history.delete(ids)
        },
        enabled = chosen.isNotEmpty(),
        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
        colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
    ) {
        Icon(Icons.Rounded.CleaningServices, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
        Text(stringResource(R.string.dictation_cleanup_confirm), style = MaterialTheme.typography.labelLarge)
    }
}
