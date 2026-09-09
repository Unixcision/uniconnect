package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.TerminalView
import com.unixcision.uniconnect.android.ui.theme.CardStyle
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The app's own preferences.
 *
 * Everything here is local to the phone: none of it reaches a machine, resizes a shared window or
 * changes a tmux session. Each change is stored as it is made, so the sheet has no save button.
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
                icon = { Icon(Icons.Rounded.Settings, null, tint = UniTheme.colors.accentSoft) },
                title = stringResource(R.string.settings),
                note = stringResource(R.string.settings_note),
                tone = UniTheme.colors.accentSoft,
            )

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
