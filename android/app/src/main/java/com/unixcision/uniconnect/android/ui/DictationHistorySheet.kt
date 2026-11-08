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
import androidx.compose.material.icons.rounded.Refresh
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
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.SentMessage
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
 * still be listened to; every message sent from the composer is kept too, with whether it
 * arrived. [preferredMachineID] is the transcriber picked in Ajustes, which «Volver a
 * transcribir» asks first.
 */
@Composable
fun DictationHistoryButton(model: DictationHistoryViewModel, draft: String, onDraftChange: (String) -> Unit, language: String? = null, preferredMachineID: String? = null) {
    val context = LocalContext.current
    var open by rememberSaveable { mutableStateOf(false) }
    val latestDraft by rememberUpdatedState(draft)
    IconButton(onClick = { open = true }) {
        Icon(Icons.Rounded.History, stringResource(R.string.history_title), tint = UniTheme.colors.muted)
    }
    if (open) DictationHistorySheet(
        model, language, preferredMachineID,
        onPaste = { text, pasted ->
            onDraftChange(DictationDraft.append(latestDraft, text))
            Toast.makeText(context, pasted, Toast.LENGTH_SHORT).show()
            open = false
        },
        onDismiss = { open = false },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DictationHistorySheet(model: DictationHistoryViewModel, language: String?, preferredMachineID: String?, onPaste: (String, Int) -> Unit, onDismiss: () -> Unit) {
    val records by model.records.collectAsStateWithLifecycle()
    val messages by model.sentMessages.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(HistoryTab.DICTATIONS) }
    val busy by model.busy.collectAsStateWithLifecycle()
    val savedMachines by model.savedMachines.collectAsStateWithLifecycle()
    val failed by model.failed.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    var playing by remember { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    // Closest first while searching; without a query, the history's own order, newest first.
    val shown = remember(records, query) { DictationSearch.rankDictations(records, query) }
    val shownMessages = remember(messages, query) { DictationSearch.rankMessages(messages, query) }
    val now = remember(records, messages) { System.currentTimeMillis() }
    val dictations = tab == HistoryTab.DICTATIONS
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
                    title = stringResource(R.string.history_title),
                    note = if (dictations) stringResource(R.string.dictation_history_note, records.size, formatSize(DictationRetention.audioBytes(records)))
                        else stringResource(R.string.sent_history_note, messages.size),
                    tone = colors.accent,
                )
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    HistoryTab.entries.forEachIndexed { index, each ->
                        SegmentedButton(
                            selected = tab == each, onClick = { tab = each },
                            shape = SegmentedButtonDefaults.itemShape(index, HistoryTab.entries.size),
                        ) { Text(stringResource(each.label)) }
                    }
                }
                Text(stringResource(R.string.dictation_history_settings_hint), style = MaterialTheme.typography.bodySmall, color = colors.muted)
                if (if (dictations) records.isNotEmpty() else messages.isNotEmpty()) OutlinedTextField(
                    value = query, onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Rounded.Search, null, tint = colors.muted) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Rounded.Close, stringResource(R.string.cancel), tint = colors.muted) } },
                    placeholder = { Text(stringResource(if (dictations) R.string.dictation_history_search else R.string.sent_history_search), color = colors.muted) },
                    shape = UniTheme.shapes.button,
                )
            }
            if (!dictations) {
                if (messages.isEmpty()) item {
                    Text(stringResource(R.string.sent_history_empty), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
                } else if (shownMessages.isEmpty()) item {
                    Text(stringResource(R.string.sent_history_no_match, query.trim()), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
                }
                items(shownMessages, key = { "m-" + it.id }) { message ->
                    SentMessageItem(
                        message, now,
                        onPaste = { onPaste(message.text, R.string.sent_history_pasted) },
                        onCopy = {
                            clipboard.setText(AnnotatedString(message.text))
                            Toast.makeText(context, R.string.dictation_history_copied, Toast.LENGTH_SHORT).show()
                        },
                        onDelete = { model.deleteSent(setOf(message.id)) },
                    )
                }
                return@LazyColumn
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
                    onPaste = { record.text?.let { onPaste(it, R.string.dictation_history_pasted) } },
                    onCopy = {
                        record.text?.let { clipboard.setText(AnnotatedString(it)) }
                        Toast.makeText(context, R.string.dictation_history_copied, Toast.LENGTH_SHORT).show()
                    },
                    onDelete = { if (playing == record.id) playing = null; model.delete(setOf(record.id)) },
                    retranscribing = record.id in busy,
                    failure = failed[record.id],
                    // Where to read it again: the automatic rule (the transcriber of Ajustes first),
                    // one machine in particular, or Whisper on this phone when it is ready.
                    retranscribeChoices = if (!model.canRetranscribe) emptyList() else buildList {
                        add(RetranscribeChoice.Automatic)
                        savedMachines.forEach { add(RetranscribeChoice.OnMachine(it)) }
                        if (model.phoneCanTranscribe) add(RetranscribeChoice.OnPhone)
                    },
                    onRetranscribe = { choice ->
                        when (choice) {
                            RetranscribeChoice.Automatic -> model.retranscribe(record, language, preferredMachineID)
                            is RetranscribeChoice.OnMachine -> model.retranscribeOn(record, language, choice.machine)
                            RetranscribeChoice.OnPhone -> model.retranscribeOnPhone(record, language)
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun DictationItem(
    record: DictationRecord, now: Long, playing: Boolean,
    onPlay: () -> Unit, onPaste: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit,
    retranscribing: Boolean = false, failure: Int? = null,
    retranscribeChoices: List<RetranscribeChoice> = emptyList(), onRetranscribe: (RetranscribeChoice) -> Unit = {},
) {
    val colors = UniTheme.colors
    var expanded by rememberSaveable(record.id) { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
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
            if (failure != null) Text(stringResource(failure), style = MaterialTheme.typography.bodySmall, color = colors.danger)
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
                // «Volver a transcribir»: the kept audio goes to its machine again, for a text that
                // came back short (only the end of a long recording) or never came at all.
                if (record.audioPath != null && retranscribeChoices.isNotEmpty()) {
                    if (retranscribing) CircularProgressIndicator(Modifier.padding(12.dp).size(24.dp), strokeWidth = 2.dp, color = colors.accent)
                    else Box {
                        IconButton(onClick = { choosing = true }) { Icon(Icons.Rounded.Refresh, stringResource(R.string.dictation_retranscribe), tint = colors.accent) }
                        DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }, containerColor = colors.surfaceRaised) {
                            retranscribeChoices.forEach { choice ->
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            when (choice) {
                                                RetranscribeChoice.Automatic -> stringResource(R.string.dictation_retranscribe_auto)
                                                is RetranscribeChoice.OnMachine -> stringResource(R.string.dictation_retranscribe_on, choice.machine.name)
                                                RetranscribeChoice.OnPhone -> stringResource(R.string.dictation_retranscribe_on_phone)
                                            },
                                        )
                                    },
                                    onClick = { choosing = false; onRetranscribe(choice) },
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDelete) { Icon(Icons.Rounded.Delete, stringResource(R.string.dictation_history_delete), tint = colors.muted) }
            }
        }
    }
}

/** Where «Volver a transcribir» reads a kept recording. */
private sealed interface RetranscribeChoice {
    /** The automatic rule: the transcriber of Ajustes, then the dictation's machine, then the rest. */
    data object Automatic : RetranscribeChoice

    /** That machine and no other. */
    data class OnMachine(val machine: Machine) : RetranscribeChoice

    /** Whisper on this phone. */
    data object OnPhone : RetranscribeChoice
}

/** The two lists of the history sheet. */
private enum class HistoryTab(val label: Int) {
    DICTATIONS(R.string.history_tab_dictations),
    MESSAGES(R.string.history_tab_messages),
}

/** One message sent from the composer: where it went, whether it arrived, and its text to paste again. */
@Composable
private fun SentMessageItem(message: SentMessage, now: Long, onPaste: () -> Unit, onCopy: () -> Unit, onDelete: () -> Unit) {
    val colors = UniTheme.colors
    var expanded by rememberSaveable(message.id) { mutableStateOf(false) }
    GlassCard(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val place = listOfNotNull(message.machineName, message.windowName).joinToString(" · ")
            Text(
                listOf(stamp(message.createdAt, now), place).filter { it.isNotEmpty() }.joinToString(" · "),
                style = MaterialTheme.typography.labelMedium, color = colors.muted,
            )
            val (state, tone) = when (message.state) {
                SentMessage.State.SENDING -> R.string.sent_state_sending to colors.muted
                SentMessage.State.DELIVERED -> R.string.sent_state_delivered to colors.success
                SentMessage.State.FAILED -> R.string.sent_state_failed to colors.danger
                SentMessage.State.UNCONFIRMED -> R.string.sent_state_unconfirmed to colors.warning
            }
            val enter = if (message.withEnter) "" else " · " + stringResource(R.string.sent_history_without_enter)
            Text(stringResource(state) + enter, style = MaterialTheme.typography.labelMedium, color = tone, fontWeight = FontWeight.SemiBold)
            var overflows by remember(message.id) { mutableStateOf(false) }
            Text(
                message.text,
                style = MaterialTheme.typography.bodyMedium, color = colors.text,
                maxLines = if (expanded) Int.MAX_VALUE else COLLAPSED_LINES,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { if (!expanded) overflows = it.hasVisualOverflow },
                modifier = Modifier.fillMaxWidth().clickable(enabled = overflows || expanded) { expanded = !expanded },
            )
            if (overflows || expanded) TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) {
                Text(stringResource(if (expanded) R.string.dictation_history_less else R.string.dictation_history_more), color = colors.accent)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onPaste) { Text(stringResource(R.string.dictation_history_paste), color = colors.accent, fontWeight = FontWeight.SemiBold) }
                IconButton(onClick = onCopy) { Icon(Icons.Rounded.ContentCopy, stringResource(R.string.dictation_history_copy), tint = colors.muted) }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDelete) { Icon(Icons.Rounded.Delete, stringResource(R.string.sent_history_delete), tint = colors.muted) }
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
