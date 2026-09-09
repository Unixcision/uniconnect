package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.TerminalKey

/** Sticky modifier state: armed applies once to the next key or text; locked stays until tapped again. */
enum class ModifierState { OFF, ARMED, LOCKED }

/**
 * Two rows of extra keys, in the spirit of Termux's extra-keys bar but on UniConnect's surface.
 * Every key resolves through [com.unixcision.uniconnect.android.domain.TerminalKeyEncoder] upstream.
 */
@Composable
fun TerminalExtraKeys(
    ctrl: ModifierState,
    alt: ModifierState,
    onCtrl: (ModifierState) -> Unit,
    onAlt: (ModifierState) -> Unit,
    enabled: Boolean,
    onKey: (TerminalKey) -> Unit,
    onText: (String) -> Unit,
) {
    var functions by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            KeyCap("ESC", stringResource(R.string.key_escape_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.ESCAPE) }
            ModifierCap(stringResource(R.string.key_ctrl), ctrl, enabled, Modifier.weight(1f), onCtrl)
            ModifierCap(stringResource(R.string.key_alt), alt, enabled, Modifier.weight(1f), onAlt)
            KeyCap("TAB", stringResource(R.string.key_tab_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.TAB) }
            KeyCap(stringResource(R.string.key_home), stringResource(R.string.key_home_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.HOME) }
            KeyCap("↑", stringResource(R.string.key_up_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.UP) }
            KeyCap(stringResource(R.string.key_end), stringResource(R.string.key_end_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.END) }
            KeyCap(stringResource(R.string.key_pgup), stringResource(R.string.key_pgup_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.PAGE_UP) }
        }
        if (functions) LazyRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            item { ToggleCap(stringResource(R.string.keys_functions), true, enabled, Modifier.width(52.dp)) { functions = false } }
            items(TerminalKey.entries.filter { it.isFunctionKey }) { key ->
                KeyCap("F${key.functionNumber}", stringResource(R.string.key_function_desc, key.functionNumber), enabled, Modifier.width(52.dp)) { onKey(key) }
            }
        } else Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ToggleCap(stringResource(R.string.keys_functions), false, enabled, Modifier.weight(1f)) { functions = true }
            KeyCap("~", "~", enabled, Modifier.weight(.8f)) { onText("~") }
            KeyCap("|", "|", enabled, Modifier.weight(.8f)) { onText("|") }
            KeyCap("-", "-", enabled, Modifier.weight(.8f)) { onText("-") }
            KeyCap("/", "/", enabled, Modifier.weight(.8f)) { onText("/") }
            KeyCap("←", stringResource(R.string.key_left_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.LEFT) }
            KeyCap("↓", stringResource(R.string.key_down_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.DOWN) }
            KeyCap("→", stringResource(R.string.key_right_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.RIGHT) }
            KeyCap(stringResource(R.string.key_pgdn), stringResource(R.string.key_pgdn_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.PAGE_DOWN) }
        }
        // Third row: the control shortcuts a terminal lives on, sent as their control byte without
        // arming Ctrl first, and Enter as a wide key of its own — the one thing the bar was missing.
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            KeyCap("^C", stringResource(R.string.key_ctrl_c_desc), enabled, Modifier.weight(1f)) { onText("\u0003") }
            KeyCap("^D", stringResource(R.string.key_ctrl_d_desc), enabled, Modifier.weight(1f)) { onText("\u0004") }
            KeyCap("^Z", stringResource(R.string.key_ctrl_z_desc), enabled, Modifier.weight(1f)) { onText("\u001a") }
            KeyCap("^L", stringResource(R.string.key_ctrl_l_desc), enabled, Modifier.weight(1f)) { onText("\u000c") }
            KeyCap(stringResource(R.string.key_del), stringResource(R.string.key_delete_desc), enabled, Modifier.weight(1f)) { onKey(TerminalKey.DELETE) }
            KeyCap(stringResource(R.string.key_enter), stringResource(R.string.key_enter_desc), enabled, Modifier.weight(2f)) { onKey(TerminalKey.ENTER) }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun KeyCap(label: String, description: String, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val shape = UniTheme.shapes.chip
    Box(
        modifier.height(42.dp).background(UniTheme.colors.surfaceRaised.copy(alpha = if (enabled) .75f else .35f), shape).border(1.dp, UniTheme.colors.outline, shape)
            .combinedClickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = if (enabled) UniTheme.colors.text else UniTheme.colors.muted, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun ToggleCap(label: String, active: Boolean, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val shape = UniTheme.shapes.chip
    Box(
        modifier.height(42.dp).background(if (active) UniTheme.colors.accentSoft.copy(alpha = .25f) else UniTheme.colors.surfaceRaised.copy(alpha = .75f), shape)
            .border(1.dp, if (active) UniTheme.colors.accentSoft.copy(alpha = .6f) else UniTheme.colors.outline, shape)
            .combinedClickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, color = if (active) UniTheme.colors.accentSoft else UniTheme.colors.muted, fontWeight = FontWeight.SemiBold)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ModifierCap(label: String, state: ModifierState, enabled: Boolean, modifier: Modifier, onChange: (ModifierState) -> Unit) {
    val shape = UniTheme.shapes.chip
    val armed = state != ModifierState.OFF
    val hint = when (state) {
        ModifierState.OFF -> stringResource(R.string.modifier_hint)
        ModifierState.ARMED -> stringResource(R.string.modifier_armed, label)
        ModifierState.LOCKED -> stringResource(R.string.modifier_locked, label)
    }
    Box(
        modifier.height(42.dp)
            .background(when (state) { ModifierState.LOCKED -> UniTheme.colors.accent; ModifierState.ARMED -> UniTheme.colors.accent.copy(alpha = .22f); ModifierState.OFF -> UniTheme.colors.surfaceRaised.copy(alpha = .75f) }, shape)
            .border(1.dp, if (armed) UniTheme.colors.accent.copy(alpha = .7f) else UniTheme.colors.outline, shape)
            .combinedClickable(
                enabled = enabled,
                onClick = { onChange(if (state == ModifierState.OFF) ModifierState.ARMED else ModifierState.OFF) },
                onLongClick = { onChange(if (state == ModifierState.LOCKED) ModifierState.OFF else ModifierState.LOCKED) },
            )
            .semantics { contentDescription = "$label. $hint" },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold,
            color = when (state) { ModifierState.LOCKED -> UniTheme.colors.onAccent; ModifierState.ARMED -> UniTheme.colors.accent; ModifierState.OFF -> if (enabled) UniTheme.colors.text else UniTheme.colors.muted })
        if (state == ModifierState.LOCKED) Box(Modifier.align(Alignment.TopEnd).padding(5.dp).size(6.dp).background(UniTheme.colors.background, CircleShape))
    }
}
