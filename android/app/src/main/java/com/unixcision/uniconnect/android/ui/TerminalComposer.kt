package com.unixcision.uniconnect.android.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ComposerAction
import com.unixcision.uniconnect.android.domain.DictationDraft
import com.unixcision.uniconnect.android.domain.DictationFailure
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationRetry
import com.unixcision.uniconnect.android.domain.DictationState
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.TerminalKeyEncoder
import com.unixcision.uniconnect.android.domain.TerminalModifiers
import com.unixcision.uniconnect.android.domain.TranscriptionCandidate
import com.unixcision.uniconnect.android.domain.TranscriptionMode
import com.unixcision.uniconnect.android.domain.TranscriptionNotice
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * A draft stays local until an explicit send, and is cleared only after host acknowledgement.
 * Armed modifiers are applied to the text through the shared encoder, exactly as the key bar does.
 *
 * With nothing typed and a way to dictate, the one floating button is a microphone: dictation
 * writes into the draft (after anything already there, never over it) and the button is send
 * again; only the "send when dictation ends" setting sends on its own. Whether the phone
 * recognises the voice or the machine transcribes the recording is decided in the model, so this
 * screen only ever reads states: a bar with partial text, a bar with a stopwatch, and a wait.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun TerminalComposer(
    enabled: Boolean,
    sending: Boolean,
    modifiers: TerminalModifiers,
    keysVisible: Boolean,
    onToggleKeys: () -> Unit,
    onSend: (String, Boolean, (Boolean) -> Unit) -> Unit,
    draft: String,
    onDraftChange: (String) -> Unit,
    dictation: DictationViewModel? = null,
    dictationLanguage: DictationLanguage = DictationLanguage.DEVICE,
    sendOnDictationEnd: Boolean = false,
    transcription: TranscriptionMode = TranscriptionMode.AUTO,
    transcriptionMachine: String? = null,
    transcribers: List<TranscriptionCandidate> = emptyList(),
    dictationTarget: DictationTarget? = null,
) {
    val context = LocalContext.current
    val send: (String, Boolean) -> Unit = { submitted, withEnter ->
        if (enabled && !sending && submitted.isNotEmpty()) {
            // The text and the Return key travel as separate writes; a single burst ending in CR
            // is read as a paste by TUIs and only inserts a line break. Never replayed on failure.
            onSend(TerminalKeyEncoder.encodeText(submitted, modifiers), withEnter) { delivered ->
                if (delivered && draft == submitted) onDraftChange("")
            }
        }
    }
    val submit: (Boolean) -> Unit = { withEnter -> send(draft, withEnter) }
    val modifierLabel = listOfNotNull(
        stringResource(R.string.key_ctrl).takeIf { modifiers.ctrl },
        stringResource(R.string.key_alt).takeIf { modifiers.alt },
    ).joinToString("+")

    // Dictation: the state comes from the model; results and failures are taken exactly once here.
    val idle = remember { MutableStateFlow<DictationState>(DictationState.Idle) }
    val dictationState by (dictation?.state ?: idle).collectAsStateWithLifecycle()
    val listening = dictationState as? DictationState.Listening
    val transcribing = dictationState as? DictationState.Transcribing
    val idleName = remember { MutableStateFlow<String?>(null) }
    val transcriber by (dictation?.transcriber ?: idleName).collectAsStateWithLifecycle()
    var notice by remember { mutableStateOf<Int?>(null) }
    var offerSettings by remember { mutableStateOf(false) }
    var retry by remember { mutableStateOf(DictationRetry.NONE) }
    var lastFailure by remember { mutableStateOf<DictationFailure?>(null) }
    val latestDraft by rememberUpdatedState(draft)
    LaunchedEffect(dictationState) {
        when (val outcome = dictationState) {
            is DictationState.Done -> {
                val merged = DictationDraft.append(latestDraft, outcome.text)
                onDraftChange(merged)
                if (sendOnDictationEnd && enabled && !sending && merged.isNotEmpty()) {
                    onSend(TerminalKeyEncoder.encodeText(merged, modifiers), true) { delivered -> if (delivered) onDraftChange("") }
                }
                retry = DictationRetry.NONE
                lastFailure = null
                dictation?.consume()
            }
            is DictationState.Failed -> {
                // Never promise a dictation on a phone that cannot listen.
                notice = if (outcome.reason == DictationFailure.HOST_UNSUPPORTED && dictation?.phoneListens != true) R.string.dictation_failed_no_transcriber_deaf
                else outcome.reason.message
                offerSettings = outcome.reason == DictationFailure.NO_PERMISSION
                retry = outcome.retry
                lastFailure = outcome.reason
                dictation?.consume()
            }
            else -> {}
        }
    }
    // The way of transcribing is remembered across the permission prompt, because a retry after
    // "no machine can" is a dictation on the phone whatever the setting says.
    var pending by remember { mutableStateOf(transcription) }
    val begin: (TranscriptionMode) -> Unit = { mode ->
        notice = null
        offerSettings = false
        retry = DictationRetry.NONE
        lastFailure = null
        dictation?.start(dictationLanguage, mode, transcribers, dictationTarget, transcriptionMachine)?.let { notice = it.message }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) begin(pending)
        else {
            // No rationale to show means the reader ticked "don't ask again": only the app's settings can undo that.
            val activity = context as? Activity
            offerSettings = activity != null && !activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
            notice = R.string.dictation_permission_denied
        }
    }
    val startDictation: (TranscriptionMode) -> Unit = { mode ->
        pending = mode
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) begin(mode)
        else permission.launch(Manifest.permission.RECORD_AUDIO)
    }
    val canDictate = dictation?.canDictate(transcription, transcribers, dictationTarget, transcriptionMachine) == true
    val action = ComposerAction.decide(draftEmpty = draft.isEmpty(), dictationAvailable = canDictate)

    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalIconButton(onClick = onToggleKeys, modifier = Modifier.size(48.dp), colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = UniTheme.colors.surfaceRaised, contentColor = UniTheme.colors.muted)) {
                Icon(if (keysVisible) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard, stringResource(if (keysVisible) R.string.keys_hide else R.string.keys_show))
            }
            if (listening != null) DictationBar(listening, Modifier.weight(1f), onCancel = { dictation?.cancel() }, onDone = { dictation?.stop() })
            else if (transcribing != null) TranscribingBar(transcribing.cut, Modifier.weight(1f), onCancel = { dictation?.cancel() })
            else Row(
                Modifier.weight(1f).background(UniTheme.colors.surface, UniTheme.shapes.card)
                    .border(1.dp, UniTheme.colors.outlineFade, UniTheme.shapes.card)
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicTextField(
                    value = draft,
                    // Keyboard Enter writes a line break into the draft; only the floating button sends.
                    onValueChange = onDraftChange,
                    modifier = Modifier.weight(1f).padding(vertical = 10.dp),
                    enabled = !sending,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = UniTheme.colors.text, fontFamily = FontFamily.Monospace),
                    cursorBrush = SolidColor(UniTheme.colors.accent),
                    minLines = 1,
                    maxLines = 6,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Default),
                    decorationBox = { field ->
                        Box {
                            if (draft.isEmpty()) Text(stringResource(R.string.terminal_input), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodyLarge)
                            field()
                        }
                    },
                )
            }
            // One floating round button outside the box, Telegram style: send, or the microphone
            // while there is nothing to send, or stop while dictating.
            val face = when {
                sending || transcribing != null -> Face.SENDING
                listening != null -> Face.STOP
                action == ComposerAction.DICTATE -> Face.MIC
                else -> Face.SEND
            }
            FilledIconButton(
                onClick = {
                    when (face) {
                        Face.STOP -> dictation?.stop()
                        Face.MIC -> startDictation(transcription)
                        Face.SEND -> submit(true)
                        Face.SENDING -> {}
                    }
                },
                enabled = when (face) {
                    Face.STOP -> true
                    Face.MIC -> enabled && !sending
                    Face.SEND -> enabled && !sending && draft.isNotEmpty()
                    Face.SENDING -> false
                },
                modifier = Modifier.size(48.dp),
                shape = CircleShape,
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = UniTheme.colors.accent, contentColor = UniTheme.colors.onAccent, disabledContainerColor = UniTheme.colors.surfaceRaised, disabledContentColor = UniTheme.colors.muted),
            ) {
                AnimatedContent(targetState = face, transitionSpec = { (fadeIn(tween(160)) + scaleIn(tween(160), .6f)) togetherWith (fadeOut(tween(120)) + scaleOut(tween(120), .6f)) }, label = "composer-face") { shown ->
                    when (shown) {
                        Face.SENDING -> LoadingIndicator(Modifier.size(22.dp), color = UniTheme.colors.onAccent)
                        Face.STOP -> Icon(Icons.Rounded.Stop, stringResource(R.string.dictation_stop), Modifier.size(22.dp))
                        Face.MIC -> Icon(Icons.Rounded.Mic, stringResource(R.string.dictation_start), Modifier.size(22.dp))
                        Face.SEND -> Icon(Icons.AutoMirrored.Rounded.Send, stringResource(R.string.terminal_send), Modifier.size(22.dp))
                    }
                }
            }
        }
        transcriber?.takeIf { listening != null || transcribing != null }?.let { name ->
            Text(
                stringResource(R.string.dictation_transcribed_by, name),
                Modifier.padding(top = 4.dp, start = 4.dp),
                color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall,
            )
        }
        notice?.let { message ->
            Row(Modifier.fillMaxWidth().padding(top = 4.dp, start = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(stringResource(message), Modifier.weight(1f), color = UniTheme.colors.warning, style = MaterialTheme.typography.labelSmall)
                if (offerSettings) TextButton(onClick = { openAppSettings(context) }, contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp)) {
                    Text(stringResource(R.string.dictation_permission_settings), style = MaterialTheme.typography.labelMedium)
                }
                // The kept recording travels once more; a recording the machine will never take is
                // recorded again instead.
                val offer = when (retry) {
                    DictationRetry.RESEND -> R.string.dictation_retry
                    DictationRetry.RERECORD -> R.string.dictation_record_again.takeIf { canDictate }
                    DictationRetry.DICTATE_ON_PHONE -> R.string.dictation_record_again.takeIf { dictation?.phoneListens == true }
                    // Offered only when the automatic rule would really reach a machine: a machine
                    // that already answered that it has no engine is not an alternative to anything.
                    DictationRetry.NONE ->
                        R.string.dictation_use_machine.takeIf {
                            lastFailure == DictationFailure.RECOGNISER_SILENT && dictation?.machineWouldTranscribe(transcribers, dictationTarget) == true
                        }
                }
                offer?.let { label ->
                    TextButton(
                        onClick = {
                            val kind = retry
                            retry = DictationRetry.NONE
                            notice = null
                            // The phone is forced here, not asked for: the automatic rule would go
                            // back to a machine that was only unreachable a moment ago.
                            when (kind) {
                                DictationRetry.RESEND -> dictation?.resend()
                                DictationRetry.DICTATE_ON_PHONE -> startDictation(TranscriptionMode.PHONE)
                                // The phone's engine is the one that failed: let a machine listen,
                                // and say so if the machines stopped being able while the line was up.
                                DictationRetry.NONE ->
                                    if (dictation?.machineWouldTranscribe(transcribers, dictationTarget) == true) startDictation(TranscriptionMode.AUTO)
                                    else notice = R.string.dictation_no_machine_now
                                else -> startDictation(transcription)
                            }
                        },
                        enabled = enabled && !sending,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp),
                    ) { Text(stringResource(label), style = MaterialTheme.typography.labelMedium) }
                }
                IconButton(onClick = { notice = null; offerSettings = false; retry = DictationRetry.NONE; lastFailure = null; dictation?.discard() }, Modifier.size(24.dp)) { Icon(Icons.Rounded.Close, stringResource(R.string.dismiss), Modifier.size(14.dp), tint = UniTheme.colors.muted) }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (modifierLabel.isNotEmpty()) Text(
                stringResource(R.string.composer_modifiers, modifierLabel),
                Modifier.background(UniTheme.colors.accent.copy(alpha = .14f), CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.accent, fontWeight = FontWeight.Bold,
            )
            val note = when {
                listening?.recording == true -> R.string.dictation_recording_note
                listening != null -> R.string.dictation_note
                transcribing != null -> R.string.dictation_transcribing_note
                else -> R.string.terminal_send_note
            }
            Text(stringResource(note), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { submit(false) }, enabled = enabled && !sending && draft.isNotEmpty() && listening == null && transcribing == null, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                Text(stringResource(R.string.terminal_send_raw), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

/** What the floating button shows. */
private enum class Face { SEND, MIC, STOP, SENDING }

/**
 * In place of the text field while dictating: a voice meter, cancel and done. What sits between
 * them depends on who is listening. The phone's recogniser writes the live text there; a recording
 * bound for the machine has none, so it shows how long has been captured instead.
 */
@Composable
private fun DictationBar(listening: DictationState.Listening, modifier: Modifier, onCancel: () -> Unit, onDone: () -> Unit) {
    val colors = UniTheme.colors
    Row(
        modifier.background(colors.surface, UniTheme.shapes.card).border(1.dp, colors.accent.copy(alpha = .5f), UniTheme.shapes.card)
            .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        VoiceMeter(listening.level)
        if (listening.recording) {
            Text(
                stringResource(R.string.dictation_recording),
                Modifier.weight(1f).padding(vertical = 8.dp),
                style = MaterialTheme.typography.bodyMedium, color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Text(
                clock(listening.seconds),
                style = MaterialTheme.typography.labelLarge, fontFamily = FontFamily.Monospace,
                color = if (listening.seconds >= WARN_SECONDS) colors.warning else colors.accent, fontWeight = FontWeight.Bold,
            )
        } else Text(
            listening.partial.ifEmpty { stringResource(R.string.dictation_listening) },
            Modifier.weight(1f).padding(vertical = 8.dp),
            style = MaterialTheme.typography.bodyMedium, fontFamily = FontFamily.Monospace,
            color = if (listening.partial.isEmpty()) colors.muted else colors.text, maxLines = 3, overflow = TextOverflow.Ellipsis,
        )
        IconButton(onClick = onCancel, Modifier.size(36.dp)) { Icon(Icons.Rounded.Close, stringResource(R.string.dictation_cancel), Modifier.size(18.dp), tint = colors.muted) }
        IconButton(onClick = onDone, Modifier.size(36.dp)) { Icon(Icons.Rounded.Check, stringResource(R.string.dictation_done), Modifier.size(20.dp), tint = colors.accent) }
    }
}

/** The wait for the machine's text; [cut] when the recording ended at the five-minute limit. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun TranscribingBar(cut: Boolean, modifier: Modifier, onCancel: () -> Unit) {
    val colors = UniTheme.colors
    Row(
        modifier.background(colors.surface, UniTheme.shapes.card).border(1.dp, colors.accent.copy(alpha = .5f), UniTheme.shapes.card)
            .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LoadingIndicator(Modifier.size(20.dp), color = colors.accent)
        Text(
            stringResource(if (cut) R.string.dictation_transcribing_cut else R.string.dictation_transcribing),
            Modifier.weight(1f).padding(vertical = 8.dp),
            style = MaterialTheme.typography.bodyMedium, color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
        IconButton(onClick = onCancel, Modifier.size(36.dp)) { Icon(Icons.Rounded.Close, stringResource(R.string.dictation_cancel), Modifier.size(18.dp), tint = colors.muted) }
    }
}

/** Five bars that follow the voice level; cheap on purpose, one animated float and no layout churn outside it. */
@Composable
private fun VoiceMeter(level: Float) {
    val eased by animateFloatAsState(level, animationSpec = tween(120), label = "voice-level")
    val accent = UniTheme.colors.accent
    Row(Modifier.height(24.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        listOf(.45f, .75f, 1f, .75f, .45f).forEach { weight ->
            Box(Modifier.width(3.dp).height(4.dp + 20.dp * eased * weight).background(accent, CircleShape))
        }
    }
}

/** Where the stopwatch turns amber, half a minute before the recording is cut. */
private const val WARN_SECONDS = 4 * 60 + 30

/** Seconds as mm:ss, so a long recording reads as a length and not as a number. */
private fun clock(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)

/** The failure in the reader's words. */
private val DictationFailure.message: Int
    get() = when (this) {
        DictationFailure.NO_PERMISSION -> R.string.dictation_failed_permission
        DictationFailure.NO_NETWORK -> R.string.dictation_failed_network
        DictationFailure.NOT_UNDERSTOOD -> R.string.dictation_failed_not_understood
        DictationFailure.ENGINE_UNAVAILABLE -> R.string.dictation_failed_engine
        DictationFailure.BUSY -> R.string.dictation_failed_busy
        DictationFailure.OTHER -> R.string.dictation_failed_other
        DictationFailure.RECOGNISER_SILENT -> R.string.dictation_failed_silent
        DictationFailure.NO_AUDIO -> R.string.dictation_failed_no_audio
        DictationFailure.TOO_LONG -> R.string.dictation_failed_too_long
        DictationFailure.HOST_LOCKED -> R.string.dictation_failed_locked
        DictationFailure.HOST_BUSY -> R.string.dictation_failed_host_busy
        DictationFailure.HOST_UNSUPPORTED -> R.string.dictation_failed_no_transcriber
        DictationFailure.HOST_FAILED -> R.string.dictation_failed_host
        DictationFailure.HOST_UNREACHABLE -> R.string.dictation_failed_host_offline
    }

/** The line about which engine ended up running. */
private val TranscriptionNotice.message: Int
    get() = when (this) {
        TranscriptionNotice.HOST_CANNOT -> R.string.dictation_host_cannot
        TranscriptionNotice.HOST_REQUIRED_UNAVAILABLE -> R.string.dictation_host_required_unavailable
        TranscriptionNotice.CHOSEN_UNAVAILABLE -> R.string.dictation_chosen_unavailable
    }

private fun openAppSettings(context: android.content.Context) {
    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
    runCatching { context.startActivity(intent) }
}
