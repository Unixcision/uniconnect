package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.AppSettings
import com.unixcision.uniconnect.android.domain.TerminalView

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
        containerColor = Brand.Surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Brand.Outline) },
    ) {
        Column(
            Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).navigationBarsPadding().padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            SheetHeader(
                icon = { Icon(Icons.Rounded.Settings, null, tint = Brand.Violet) },
                title = stringResource(R.string.settings),
                note = stringResource(R.string.settings_note),
                tone = Brand.Violet,
            )

            SettingsSection(stringResource(R.string.settings_terminal)) {
                Text(stringResource(R.string.settings_default_view), style = MaterialTheme.typography.bodyMedium)
                Text(stringResource(R.string.settings_default_view_note), color = Brand.Muted, style = MaterialTheme.typography.bodySmall)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    TerminalView.entries.forEachIndexed { index, view ->
                        SegmentedButton(
                            selected = settings.terminalView == view,
                            onClick = { onChange(settings.copy(terminalView = view)) },
                            shape = SegmentedButtonDefaults.itemShape(index, TerminalView.entries.size),
                            colors = SegmentedButtonDefaults.colors(
                                activeContainerColor = Brand.Violet.copy(alpha = .22f),
                                activeContentColor = Brand.Violet, inactiveContentColor = Brand.Muted,
                            ),
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
                color = Brand.Muted, style = MaterialTheme.typography.labelSmall,
            )
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.close), color = Brand.Muted) }
        }
    }
}

/** A titled group of related preferences. */
@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, color = Brand.Cyan, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
        Surface(color = Brand.DeepBlue.copy(alpha = .45f), shape = RoundedCornerShape(18.dp)) {
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
            Text(note, color = Brand.Muted, style = MaterialTheme.typography.bodySmall)
        }
        Switch(
            checked = checked, onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Brand.Cyan, checkedThumbColor = Brand.Night),
        )
    }
}

/** The name this reading is offered under, shared with the terminal's own button. */
private val TerminalView.label: Int
    get() = when (this) {
        TerminalView.FIT -> R.string.view_short_fit
        TerminalView.WRAP -> R.string.view_short_wrap
        TerminalView.PAN -> R.string.view_short_pan
    }
