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
import androidx.compose.material.icons.rounded.Search
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DictationDraft
import com.unixcision.uniconnect.android.domain.DictationRecord
import com.unixcision.uniconnect.android.domain.DictationRetention
import com.unixcision.uniconnect.android.domain.DictationSearch
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
    var query by rememberSaveable { mutableStateOf("") }
    val shown = remember(records, query) { records.filter { DictationSearch.matches(it, query) } }
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
                Text(stringResource(R.string.dictation_history_settings_hint), style = MaterialTheme.typography.bodySmall, color = colors.muted)
                if (records.isNotEmpty()) OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Rounded.Search, null, tint = colors.muted) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Rounded.Close, stringResource(R.string.cancel), tint = colors.muted) } },
                    placeholder = { Text(stringResource(R.string.dictation_history_search), color = colors.muted) },
                    shape = UniTheme.shapes.button,
                )
            }
            if (records.isEmpty()) item {
                Text(stringResource(R.string.dictation_history_empty), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
            } else if (shown.isEmpty()) item {
                Text(stringResource(R.string.dictation_history_no_match, query.trim()), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
            }
            items(shown, key = { it.id }) { record ->
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
            // Long dictations fold to a few lines: the card stays small and opens like an accordion.
            var overflows by remember(record.id, body) { mutableStateOf(false) }
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                color = if (record.text != null) colors.text else colors.warning,
                maxLines = if (expanded) Int.MAX_VALUE else COLLAPSED_LINES,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { if (!expanded) overflows = it.hasVisualOverflow },
                modifier = Modifier.fillMaxWidth().clickable(enabled = overflows || expanded) { expanded = !expanded },
            )
            if (overflows || expanded) TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) {
                Text(stringResource(if (expanded) R.string.dictation_history_less else R.string.dictation_history_more), color = colors.accent)
            }
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

/** Lines a folded dictation shows before «Ver todo». */
private const val COLLAPSED_LINES = 3
