package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.ColorMode
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.domain.ByteSize
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.SpeechModel
import com.unixcision.uniconnect.android.domain.SpeechModelFailure
import com.unixcision.uniconnect.android.domain.SpeechModelState
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.domain.TranscriptionCandidate
import com.unixcision.uniconnect.android.domain.TranscriptionMode
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
import com.unixcision.uniconnect.android.ui.theme.CardStyle
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.ui.theme.UniTokens

/**
 * The app's own preferences.
 *
 * Everything here is local to the phone: none of it reaches a machine, resizes a shared window or
 * changes a tmux session. Each change is stored as it is made, so the sheet has no save button;
 * a new theme or colour mode is on screen before the sheet is closed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    settings: AppSettings,
    transcribers: List<TranscriptionCandidate>,
    dictation: DictationViewModel?,
    onChange: (AppSettings) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val version = remember(context) {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull().orEmpty()
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = UniTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = UniTheme.colors.outline) },
    ) {
        Column(
            Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            SheetHeader(
                icon = { Icon(Icons.Rounded.Settings, null, tint = UniTheme.colors.accent) },
                title = stringResource(R.string.settings),
                note = stringResource(R.string.settings_note),
                tone = UniTheme.colors.accent,
            )

            SettingsSection(stringResource(R.string.settings_appearance)) {
                Text(stringResource(R.string.settings_design_theme), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.settings_design_theme_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                // A fixed width per card and a scroll, not five slivers sharing the sheet: the
                // thumbnail has to be big enough to show a floating surface and the name has to
                // fit whole.
                Row(
                    Modifier.fillMaxWidth().padding(top = 10.dp).horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    DesignTheme.entries.forEach { theme ->
                        ThemeCard(theme, selected = settings.designTheme == theme, dark = UniTheme.colors.isDark, Modifier.width(96.dp)) {
                            onChange(settings.copy(designTheme = theme))
                        }
                    }
                }
                Text(stringResource(R.string.settings_color_mode), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.settings_color_mode_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    ColorMode.entries.forEachIndexed { index, mode ->
                        SegmentedButton(
                            selected = settings.colorMode == mode,
                            onClick = { onChange(settings.copy(colorMode = mode)) },
                            shape = SegmentedButtonDefaults.itemShape(index, ColorMode.entries.size),
                            colors = segmentColors(),
                        ) { Text(stringResource(mode.label), style = MaterialTheme.typography.labelMedium) }
                    }
                }
            }

            SettingsSection(stringResource(R.string.settings_terminal)) {
                Text(stringResource(R.string.settings_default_view), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.settings_default_view_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    TerminalView.entries.forEachIndexed { index, view ->
                        SegmentedButton(
                            selected = settings.terminalView == view,
                            onClick = { onChange(settings.copy(terminalView = view)) },
                            shape = SegmentedButtonDefaults.itemShape(index, TerminalView.entries.size),
                            colors = segmentColors(),
                        ) { Text(stringResource(view.label), style = MaterialTheme.typography.labelMedium) }
                    }
                }
                SettingsSwitch(
                    title = stringResource(R.string.settings_extra_keys),
                    note = stringResource(R.string.settings_extra_keys_note),
                    checked = settings.showExtraKeys,
                    onChange = { onChange(settings.copy(showExtraKeys = it)) },
                )
            }

            SettingsSection(stringResource(R.string.settings_voice)) {
                Text(stringResource(R.string.settings_transcription), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.settings_transcription_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                // A row of segments could not say who transcribes, and that is the only thing worth
                // saying here: each way gets a line of its own under its name.
                Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                    TranscriptionMode.entries.forEach { mode ->
                        ChoiceRow(
                            title = stringResource(mode.label),
                            note = stringResource(mode.note),
                            selected = settings.transcription == mode,
                            // Picking "one machine" with none picked yet starts on the first that can.
                            onSelect = {
                                val chosen = if (mode == TranscriptionMode.MACHINE) settings.transcriptionMachine ?: transcribers.firstOrNull { it.transcribes }?.machine?.id
                                else settings.transcriptionMachine
                                onChange(settings.copy(transcription = mode, transcriptionMachine = chosen))
                            },
                        )
                        if (mode == TranscriptionMode.MACHINE && settings.transcription == TranscriptionMode.MACHINE) {
                            TranscriberPicker(settings, transcribers, onChange)
                        }
                        if (mode == TranscriptionMode.LOCAL && settings.transcription == TranscriptionMode.LOCAL && dictation?.localReady != true) {
                            Text(
                                stringResource(if (dictation?.whisperRuns == false) R.string.settings_whisper_unsupported else R.string.settings_whisper_needs_model),
                                Modifier.padding(start = 32.dp, bottom = 4.dp),
                                color = UniTheme.colors.warning, style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                }
                SettingsSwitch(
                    title = stringResource(R.string.settings_send_on_dictation),
                    note = stringResource(R.string.settings_send_on_dictation_note),
                    checked = settings.sendOnDictationEnd,
                    onChange = { onChange(settings.copy(sendOnDictationEnd = it)) },
                )
                Text(stringResource(R.string.settings_dictation_language), Modifier.padding(top = 6.dp), style = MaterialTheme.typography.bodyMedium)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                    DictationLanguage.entries.forEachIndexed { index, language ->
                        SegmentedButton(
                            selected = settings.dictationLanguage == language,
                            onClick = { onChange(settings.copy(dictationLanguage = language)) },
                            shape = SegmentedButtonDefaults.itemShape(index, DictationLanguage.entries.size),
                            colors = segmentColors(),
                        ) { Text(stringResource(language.label), style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                }
            }

            if (dictation != null) SettingsSection(stringResource(R.string.settings_speech_models)) {
                Text(stringResource(R.string.settings_speech_models_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                if (!dictation.whisperRuns) Text(
                    stringResource(R.string.settings_whisper_unsupported),
                    color = UniTheme.colors.warning, style = MaterialTheme.typography.labelSmall,
                ) else {
                    val states by dictation.models.collectAsStateWithLifecycle()
                    SpeechModel.entries.forEach { model ->
                        SpeechModelRow(
                            model = model,
                            state = states[model] ?: SpeechModelState.Missing,
                            onDownload = { dictation.download(model) },
                            onCancel = { dictation.cancelDownload(model) },
                            onDelete = { dictation.deleteModel(model) },
                        )
                    }
                    // Measured, not promised. How long this phone takes is the only thing that
                    // decides whether the model is worth keeping, and it depends on the phone.
                    dictation.lastWhisperRun()?.takeIf { it.tookMillis > 0 }?.let { run ->
                        Text(
                            stringResource(R.string.speech_model_last_run, "%.0f".format(run.seconds), "%.1f".format(run.tookMillis / 1000.0)),
                            Modifier.padding(top = 4.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
            }

            SettingsSection(stringResource(R.string.settings_terminal_upload)) {
                Text(stringResource(R.string.settings_terminal_upload_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
                TerminalUploadPicker(settings, onChange)
            }

            SettingsSection(stringResource(R.string.settings_connections)) {
                SettingsSwitch(
                    title = stringResource(R.string.settings_probe_on_open),
                    note = stringResource(R.string.settings_probe_on_open_note),
                    checked = settings.probeOnOpen,
                    onChange = { onChange(settings.copy(probeOnOpen = it)) },
                )
            }

            Text(
                stringResource(R.string.settings_version, version),
                color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall,
            )
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.close), color = UniTheme.colors.muted) }
        }
    }
}

/**
 * One design theme to pick, drawn in its own palette for the mode in force: its ground, a small
 * surface on it, its accent and two lines of text. The surface is separated the way the theme
 * separates one, so a floating theme shows its shadow (or its lift, in the dark) here and a flat
 * theme shows its rule. The name is set in the theme's own type, so the serif and the monospace
 * announce themselves before they are chosen.
 */
@Composable
private fun ThemeCard(theme: DesignTheme, selected: Boolean, dark: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val preview = remember(theme, dark) { UniTokens.tokensFor(theme, dark) }
    val palette = preview.colors
    val elevation = preview.elevation
    val shape = RoundedCornerShape(preview.shapes.cardRadius.coerceIn(6.dp, 18.dp))
    val inner = RoundedCornerShape(preview.shapes.cardRadius.coerceIn(3.dp, 12.dp))
    Column(
        modifier.clip(shape).background(palette.background)
            .border(if (selected) 2.dp else 1.dp, if (selected) UniTheme.colors.accent else UniTheme.colors.outline, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(10.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().height(52.dp)
                // Halved so a 52 dp thumbnail is not swallowed by a shadow sized for a real card.
                .then(if (elevation.ambient > 0.dp) Modifier.shadow(elevation.ambient / 2, inner, clip = false, ambientColor = elevation.ambientColor, spotColor = elevation.ambientColor) else Modifier)
                .then(if (elevation.key > 0.dp) Modifier.shadow(elevation.key, inner, clip = false, ambientColor = elevation.keyColor, spotColor = elevation.keyColor) else Modifier)
                .clip(inner)
                .background(palette.surface)
                .then(if (elevation.surfaceLift > 0f) Modifier.background(Color.White.copy(alpha = elevation.surfaceLift)) else Modifier)
                .border(elevation.hairline, palette.outline, inner)
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.width(20.dp).height(5.dp).background(palette.accent, CircleShape))
            Box(Modifier.fillMaxWidth(.85f).height(4.dp).background(palette.text.copy(alpha = .85f), CircleShape))
            Box(Modifier.fillMaxWidth(.55f).height(4.dp).background(palette.muted, CircleShape))
        }
        Text(
            stringResource(theme.label), style = MaterialTheme.typography.labelSmall,
            color = if (selected) UniTheme.colors.accent else UniTheme.colors.text, fontWeight = FontWeight.SemiBold,
            fontFamily = if (preview.type.identifierFamily == FontFamily.Monospace) preview.type.identifierFamily else preview.type.headlineFamily,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The fallback service of the terminal's clip: the same as "Enviar archivos" (the default), one
 * of the presets, or a custom one that may be a full URL with scheme, host, port and path. It is
 * kept apart from the page's own service and never changes it.
 */
@Composable
private fun TerminalUploadPicker(settings: AppSettings, onChange: (AppSettings) -> Unit) {
    val chosen = settings.terminalUploadService
    var editing by rememberSaveable { mutableStateOf(false) }
    val custom = chosen != null && !chosen.isPreset
    var url by rememberSaveable(chosen) { mutableStateOf(if (custom) chosen?.domain.orEmpty() else "") }
    var style by rememberSaveable(chosen) { mutableStateOf(if (custom) chosen?.style ?: UploadStyle.RAW_NAMED else UploadStyle.RAW_NAMED) }
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ServiceChip(stringResource(R.string.terminal_upload_same, settings.uploadService.domain), selected = !editing && chosen == null) {
            editing = false; onChange(settings.copy(terminalUploadService = null))
        }
        UploadService.presets.forEach { preset ->
            ServiceChip(preset.domain, selected = !editing && chosen == preset) { editing = false; onChange(settings.copy(terminalUploadService = preset)) }
        }
        ServiceChip(stringResource(R.string.upload_custom), selected = editing || custom) { editing = true }
    }
    Text(stringResource(R.string.upload_service_note_short, settings.terminalUpload.baseUrl), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
    if (editing || custom) {
        SheetField(url, { url = it }, stringResource(R.string.upload_url), hint = stringResource(R.string.upload_url_hint), monospace = true, keyboard = KeyboardType.Uri)
        Text(stringResource(R.string.upload_style), style = MaterialTheme.typography.bodyMedium)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            UploadStyle.entries.forEachIndexed { index, candidate ->
                SegmentedButton(
                    selected = style == candidate, onClick = { style = candidate },
                    shape = SegmentedButtonDefaults.itemShape(index, UploadStyle.entries.size), colors = segmentColors(),
                ) { Text(stringResource(candidate.label), style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
        val normalized = UploadService.normalizeUrl(url)
        Button(
            onClick = { onChange(settings.copy(terminalUploadService = UploadService(normalized, style))); editing = false },
            enabled = normalized.isNotEmpty(), modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button,
        ) { Text(stringResource(R.string.upload_save_service), fontWeight = FontWeight.SemiBold) }
    }
}

/**
 * The machines a recording may be sent to, with what stops each one from taking it right now. A
 * machine that cannot is still worth picking: it may be the one with the good model, and today it
 * is only asleep. While it cannot, the automatic rule runs instead and the composer says so.
 */
@Composable
private fun TranscriberPicker(settings: AppSettings, transcribers: List<TranscriptionCandidate>, onChange: (AppSettings) -> Unit) {
    if (transcribers.isEmpty()) {
        Text(stringResource(R.string.settings_transcription_no_machines), Modifier.padding(top = 8.dp), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
        return
    }
    Column(Modifier.fillMaxWidth().padding(top = 6.dp)) {
        transcribers.forEach { candidate ->
            val chosen = settings.transcriptionMachine == candidate.machine.id
            Row(
                Modifier.fillMaxWidth()
                    .selectable(selected = chosen, role = Role.RadioButton) { onChange(settings.copy(transcriptionMachine = candidate.machine.id)) }
                    .padding(vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = chosen, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = UniTheme.colors.accent, unselectedColor = UniTheme.colors.outline))
                Column(Modifier.padding(start = 8.dp)) {
                    Text(candidate.machine.name, style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.text)
                    val mark = when {
                        !candidate.connected -> R.string.settings_transcription_offline
                        !candidate.transcribes -> R.string.settings_transcription_cannot
                        else -> null
                    }
                    mark?.let { Text(stringResource(it), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall) }
                }
            }
        }
    }
}

/** The visible name of a way of transcribing. */
private val TranscriptionMode.label: Int
    get() = when (this) {
        TranscriptionMode.AUTO -> R.string.transcription_auto
        TranscriptionMode.MACHINE -> R.string.transcription_machine
        TranscriptionMode.LOCAL -> R.string.transcription_local
        TranscriptionMode.PHONE -> R.string.transcription_phone
    }

/** The sentence under it, which says who ends up transcribing. */
private val TranscriptionMode.note: Int
    get() = when (this) {
        TranscriptionMode.AUTO -> R.string.transcription_auto_note
        TranscriptionMode.MACHINE -> R.string.transcription_machine_note
        TranscriptionMode.LOCAL -> R.string.transcription_local_note
        TranscriptionMode.PHONE -> R.string.transcription_phone_note
    }

/** The visible name of a model, and the sentence that says what it costs. */
private val SpeechModel.label: Int
    get() = when (this) {
        SpeechModel.BASE -> R.string.speech_model_base
        SpeechModel.SMALL -> R.string.speech_model_small
    }

private val SpeechModel.note: Int
    get() = when (this) {
        SpeechModel.BASE -> R.string.speech_model_base_note
        SpeechModel.SMALL -> R.string.speech_model_small_note
    }

/** Why a download did not finish, in the reader's words. */
private val SpeechModelFailure.message: Int
    get() = when (this) {
        SpeechModelFailure.NO_SPACE -> R.string.speech_model_no_space
        SpeechModelFailure.NETWORK -> R.string.speech_model_network
        SpeechModelFailure.CORRUPT -> R.string.speech_model_corrupt
        SpeechModelFailure.WRITE_FAILED -> R.string.speech_model_write_failed
    }

/**
 * One way of transcribing, with the sentence that says who does it. A radio and two lines, not a
 * segment: the name alone ("Automática") does not tell anyone where their voice goes.
 */
@Composable
private fun ChoiceRow(title: String, note: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, role = Role.RadioButton, onClick = onSelect).padding(vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        RadioButton(
            selected = selected, onClick = null,
            colors = RadioButtonDefaults.colors(selectedColor = UniTheme.colors.accent, unselectedColor = UniTheme.colors.outline),
        )
        Column(Modifier.padding(start = 8.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, color = if (selected) UniTheme.colors.accent else UniTheme.colors.text)
            Text(note, color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
        }
    }
}

/**
 * One Whisper model: what it is, what it costs and the single thing worth doing to it right now.
 *
 * Nothing here starts on its own. A model is fetched because this button was pressed, the bar
 * shows what is on the phone rather than what this attempt fetched (so a resumed download does not
 * appear to start over), and deleting says how much storage comes back.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun SpeechModelRow(
    model: SpeechModel,
    state: SpeechModelState,
    onDownload: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).padding(end = 8.dp)) {
                Text(stringResource(model.label), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(model.note, ByteSize.format(model.bytes)), color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
            }
            when (state) {
                is SpeechModelState.Downloading -> TextButton(onClick = onCancel, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                    Text(stringResource(R.string.speech_model_stop), style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false)
                }
                is SpeechModelState.Ready -> IconButton(onClick = onDelete, Modifier.size(36.dp)) {
                    Icon(Icons.Rounded.Delete, stringResource(R.string.speech_model_delete), Modifier.size(18.dp), tint = UniTheme.colors.muted)
                }
                else -> TextButton(onClick = onDownload, contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                    Text(
                        stringResource(if (state is SpeechModelState.Paused) R.string.speech_model_resume else R.string.speech_model_download),
                        style = MaterialTheme.typography.labelMedium, maxLines = 1, softWrap = false,
                    )
                }
            }
        }
        val status = when (state) {
            SpeechModelState.Missing -> stringResource(R.string.speech_model_missing)
            is SpeechModelState.Downloading -> stringResource(R.string.speech_model_downloading, ByteSize.percent(state.downloaded, state.total), ByteSize.format(state.downloaded))
            is SpeechModelState.Paused -> stringResource(R.string.speech_model_paused, ByteSize.percent(state.downloaded, state.total))
            is SpeechModelState.Ready -> stringResource(R.string.speech_model_ready, ByteSize.format(state.bytes))
            is SpeechModelState.Failed -> stringResource(state.reason.message)
        }
        Text(
            status,
            color = if (state is SpeechModelState.Failed) UniTheme.colors.warning else UniTheme.colors.muted,
            style = MaterialTheme.typography.labelSmall,
        )
        if (state is SpeechModelState.Downloading || state is SpeechModelState.Paused) LinearProgressIndicator(
            progress = { state.fraction },
            modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
            color = UniTheme.colors.accent,
            trackColor = UniTheme.colors.outline,
        )
    }
}

/** The visible name of a dictation language. */
private val DictationLanguage.label: Int
    get() = when (this) {
        DictationLanguage.DEVICE -> R.string.dictation_language_device
        DictationLanguage.ES_ES -> R.string.dictation_language_es
        DictationLanguage.EN_US -> R.string.dictation_language_en
    }

/** The visible name of an upload style. */
private val UploadStyle.label: Int
    get() = when (this) {
        UploadStyle.RAW_NAMED -> R.string.upload_style_raw
        UploadStyle.MULTIPART_FILE -> R.string.upload_style_multipart
        UploadStyle.LITTERBOX -> R.string.upload_style_litterbox
    }

/** A titled group of related preferences: a soft container, or rules above and below in a hairline theme. */
@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    val quiet = UniTheme.type.labelQuiet
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            title,
            color = if (quiet) UniTheme.colors.muted else UniTheme.colors.accent,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = if (quiet) FontWeight.Medium else FontWeight.SemiBold,
        )
        if (UniTheme.layout.cardsAs == CardStyle.HAIRLINE) {
            val rule = UniTheme.colors.outline
            Column(
                Modifier.fillMaxWidth().drawBehind {
                    val stroke = 1.dp.toPx()
                    drawLine(rule, Offset(0f, stroke / 2), Offset(size.width, stroke / 2), stroke)
                    drawLine(rule, Offset(0f, size.height - stroke / 2), Offset(size.width, size.height - stroke / 2), stroke)
                }.padding(vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp), content = content,
            )
        } else Surface(color = UniTheme.colors.surfaceRaised.copy(alpha = .45f), shape = UniTheme.shapes.card) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
    }
}

/** One on/off preference with the sentence that explains what it costs. */
@Composable
private fun SettingsSwitch(title: String, note: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(note, color = UniTheme.colors.muted, style = MaterialTheme.typography.bodySmall)
        }
        Switch(
            checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = UniTheme.colors.accent, checkedThumbColor = UniTheme.colors.onAccent),
        )
    }
}

@Composable
private fun segmentColors() = SegmentedButtonDefaults.colors(
    activeContainerColor = UniTheme.colors.accent.copy(alpha = .18f), activeContentColor = UniTheme.colors.accent,
    activeBorderColor = UniTheme.colors.accent.copy(alpha = .5f), inactiveContentColor = UniTheme.colors.muted,
    inactiveBorderColor = UniTheme.colors.outline,
)

/** The name this reading is offered under, shared with the terminal's own button. */
private val TerminalView.label: Int
    get() = when (this) {
        TerminalView.FIT -> R.string.view_short_fit
        TerminalView.WRAP -> R.string.view_short_wrap
        TerminalView.PAN -> R.string.view_short_pan
    }

/** The visible name of a design theme. */
private val DesignTheme.label: Int
    get() = when (this) {
        DesignTheme.NIEVE -> R.string.theme_nieve
        DesignTheme.SERENO -> R.string.theme_sereno
        DesignTheme.SENAL -> R.string.theme_senal
        DesignTheme.TINTA -> R.string.theme_tinta
        DesignTheme.TERMINAL -> R.string.theme_terminal
    }

/** The visible name of a colour mode. */
private val ColorMode.label: Int
    get() = when (this) {
        ColorMode.LIGHT -> R.string.color_mode_light
        ColorMode.DARK -> R.string.color_mode_dark
        ColorMode.SYSTEM -> R.string.color_mode_system
    }
