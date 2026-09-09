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
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.ColorMode
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.domain.TerminalView
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
fun SettingsSheet(settings: AppSettings, onChange: (AppSettings) -> Unit, onDismiss: () -> Unit) {
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
                Row(Modifier.fillMaxWidth().padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    DesignTheme.entries.forEach { theme ->
                        ThemeCard(theme, selected = settings.designTheme == theme, dark = UniTheme.colors.isDark, Modifier.weight(1f)) {
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
 * card on it, its accent and two lines of text. The name is set in the theme's own type, so the
 * serif and the monospace announce themselves before they are chosen.
 */
@Composable
private fun ThemeCard(theme: DesignTheme, selected: Boolean, dark: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val preview = remember(theme, dark) { UniTokens.tokensFor(theme, dark) }
    val palette = preview.colors
    val shape = RoundedCornerShape(preview.shapes.cardRadius.coerceIn(4.dp, 14.dp))
    val inner = RoundedCornerShape(preview.shapes.cardRadius.coerceIn(2.dp, 8.dp))
    Column(
        modifier.clip(shape).background(palette.background)
            .border(if (selected) 2.dp else 1.dp, if (selected) UniTheme.colors.accent else UniTheme.colors.outline, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(6.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().height(46.dp).background(palette.surface, inner).border(1.dp, palette.outline, inner).padding(6.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(Modifier.width(18.dp).height(5.dp).background(palette.accent, CircleShape))
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
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, color = UniTheme.colors.accent, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
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
