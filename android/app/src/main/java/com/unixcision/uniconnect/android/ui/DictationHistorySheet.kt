package com.unixcision.uniconnect.android.ui

import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DictationDraft
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationRetention
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * The history button beside the clip. Every dictation is kept with its audio and its text, so
 * one cut short on its way to the window can be pasted again, and one no engine could read can
 * still be listened to.
 */
@Composable
fun DictationHistoryButton(model: DictationHistoryViewModel, draft: String, onDraftChange: (String) -> Unit) {
    val context = LocalContext.current
    var open by rememberSaveable { mutableStateOf(false) }
    val latestDraft by rememberUpdatedState(draft)
    IconButton(onClick = { open = true }) {
        Icon(Icons.Rounded.History, stringResource(R.string.dictation_history_title), tint = UniTheme.colors.muted)
    }
    if (open) DictationHistorySheet(
        model,
        onPaste = { text ->
            onDraftChange(DictationDraft.append(latestDraft, text))
            Toast.makeText(context, R.string.dictation_history_pasted, Toast.LENGTH_SHORT).show()
            open = false
        },
        onDismiss = { open = false },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DictationHistorySheet(model: DictationHistoryViewModel, onPaste: (String) -> Unit, onDismiss: () -> Unit) {
    val records by model.records.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var playing by remember { mutableStateOf<String?>(null) }
    var cleaning by remember { mutableStateOf(false) }
    val now = remember(records) { System.currentTimeMillis() }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = colors.outline) },
    ) {
        LazyColumn(
            Modifier.fillMaxWidth().navigationBarsPadding(),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                SheetHeader(
                    icon = { Icon(Icons.Rounded.History, null, tint = colors.accent) },
                    title = stringResource(R.string.dictation_history_title),
                    note = stringResource(R.string.dictation_history_note, records.size, formatSize(DictationRetention.audioBytes(records))),
                    tone = colors.accent,
                )
                if (records.isNotEmpty()) TextButton(onClick = { cleaning = true }) {
                    Text(stringResource(R.string.dictation_history_free), color = colors.accent)
                }
            }
            if (records.isEmpty()) item {
                Text(stringResource(R.string.dictation_history_empty), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
            }
            items(records, key = { it.id }) { record ->
                DictationItem(
                    record, now, playing = playing == record.id,
                    onPlay = { playing = if (playing == record.id) null else record.id },
                    onPaste = { record.text?.let(onPaste) },
                    onCopy = {
                        record.text?.let { clipboard.setText(AnnotatedString(it)) }
                        Toast.makeText(context, R.string.dictation_history_copied, Toast.LENGTH_SHORT).show()
                    },
                    onDelete = { if (playing == record.id) playing = null; model.delete(setOf(record.id)) },
                )
            }
        }
    }
    if (cleaning) DictationCleanupDialog(
        records, now,
        onClean = { ids, audioOnly ->
            if (playing in ids) playing = null
            if (audioOnly) model.deleteAudio(ids) else model.delete(ids)
            cleaning = false
        },
        onDismiss = { cleaning = false },
    )
}

@Composable
private fun DictationItem(
    record: DictationRecord, now: Long, playing: Boolean,
    onPlay: () -> Unit, onPaste: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit,
) {
    val colors = UniTheme.colors
    var expanded by rememberSaveable(record.id) { mutableStateOf(false) }
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val place = record.machineName ?: stringResource(R.string.dictation_history_phone)
            val length = if (record.audioPath != null) " · %d:%02d".format(record.seconds / 60, record.seconds % 60) else ""
            Text("${stamp(record.createdAt, now)} · $place$length", style = MaterialTheme.typography.labelMedium, color = colors.muted)
            val body = record.text ?: stringResource(
                if (record.state == DictationRecord.State.TRANSCRIBING) R.string.dictation_history_transcribing else R.string.dictation_history_unread,
            )
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                color = if (record.text != null) colors.text else colors.warning,
                maxLines = if (expanded) Int.MAX_VALUE else 4,
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
            )
            if (playing && record.audioPath != null) InboxMediaPlayer(Uri.fromFile(File(record.audioPath)), audio = true)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (record.text != null) {
                    TextButton(onClick = onPaste) { Text(stringResource(R.string.dictation_history_paste), color = colors.accent, fontWeight = FontWeight.SemiBold) }
                    IconButton(onClick = onCopy) { Icon(Icons.Rounded.ContentCopy, stringResource(R.string.dictation_history_copy), tint = colors.muted) }
                }
                if (record.audioPath != null) IconButton(onClick = onPlay) {
                    Icon(
                        if (playing) Icons.Rounded.Close else Icons.Rounded.PlayArrow,
                        stringResource(if (playing) R.string.dictation_history_stop else R.string.dictation_history_play),
                        tint = colors.accent,
                    )
                } else Text(stringResource(R.string.dictation_history_no_audio), style = MaterialTheme.typography.labelSmall, color = colors.muted)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDelete) { Icon(Icons.Rounded.Delete, stringResource(R.string.dictation_history_delete), tint = colors.muted) }
            }
        }
    }
}

/** «Liberar espacio»: by age, only the audio (the text stays) or the whole entries. */
@Composable
private fun DictationCleanupDialog(
    records: List<DictationRecord>, now: Long,
    onClean: (Set<String>, Boolean) -> Unit, onDismiss: () -> Unit,
) {
    val colors = UniTheme.colors
    var days by remember { mutableStateOf<Int?>(7) }
    var audioOnly by remember { mutableStateOf(true) }
    val chosen = DictationRetention.olderThan(records, now, days?.let { it * DictationRetention.DAY_MILLIS })
        .let { list -> if (audioOnly) list.filter { it.audioPath != null } else list }
    val freed = DictationRetention.audioBytes(chosen)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colors.surfaceRaised,
        title = { Text(stringResource(R.string.dictation_cleanup_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.dictation_cleanup_age), style = MaterialTheme.typography.labelLarge, color = colors.muted)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(1 to R.string.inbox_cleanup_day, 7 to R.string.inbox_cleanup_week, 30 to R.string.inbox_cleanup_month).forEach { (value, label) ->
                        ServiceChip(stringResource(label), selected = days == value) { days = value }
                    }
                    ServiceChip(stringResource(R.string.dictation_cleanup_all_ages), selected = days == null) { days = null }
                }
                ServiceChip(stringResource(R.string.dictation_cleanup_audio_only), selected = audioOnly) { audioOnly = true }
                ServiceChip(stringResource(R.string.dictation_cleanup_everything), selected = !audioOnly) { audioOnly = false }
                Text(
                    when {
                        chosen.isEmpty() -> stringResource(R.string.dictation_cleanup_nothing)
                        audioOnly -> stringResource(R.string.dictation_cleanup_estimate_audio, chosen.size, formatSize(freed))
                        else -> stringResource(R.string.dictation_cleanup_estimate_all, chosen.size, formatSize(freed))
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onClean(chosen.mapTo(mutableSetOf()) { it.id }, audioOnly) },
                enabled = chosen.isNotEmpty(),
                colors = ButtonDefaults.buttonColors(containerColor = colors.danger, contentColor = colors.onAccent),
                shape = UniTheme.shapes.button,
            ) { Text(stringResource(R.string.dictation_cleanup_confirm), fontWeight = FontWeight.SemiBold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel), color = colors.muted) } },
    )
}

/** «Hoy 18:02», «Ayer 18:02» or «13 oct 18:02». */
@Composable
private fun stamp(at: Long, now: Long): String {
    val time = SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(at))
    val day = Calendar.getInstance().apply { timeInMillis = at }
    val today = Calendar.getInstance().apply { timeInMillis = now }
    val sameYear = day.get(Calendar.YEAR) == today.get(Calendar.YEAR)
    return when {
        sameYear && day.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR) -> stringResource(R.string.dictation_history_today, time)
        sameYear && day.get(Calendar.DAY_OF_YEAR) == today.get(Calendar.DAY_OF_YEAR) - 1 -> stringResource(R.string.dictation_history_yesterday, time)
        else -> SimpleDateFormat("d MMM HH:mm", Locale.getDefault()).format(Date(at))
    }
}
