package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.TerminalKeyEncoder
import com.unixcision.uniconnect.android.domain.TerminalModifiers

/**
 * A draft stays local until an explicit send, and is cleared only after host acknowledgement.
 * Armed modifiers are applied to the text through the shared encoder, exactly as the key bar does.
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
) {
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
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalIconButton(onClick = onToggleKeys, modifier = Modifier.size(48.dp), colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = UniTheme.colors.surfaceRaised, contentColor = UniTheme.colors.muted)) {
                Icon(if (keysVisible) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard, stringResource(if (keysVisible) R.string.keys_hide else R.string.keys_show))
            }
            Row(
                Modifier.weight(1f).background(UniTheme.colors.surface, UniTheme.shapes.card)
                    .border(1.dp, Brush.linearGradient(listOf(UniTheme.colors.glassTop, UniTheme.colors.glassBottom)), UniTheme.shapes.card)
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
            // Floating round send button outside the box, Telegram style: this is the only thing that sends.
            FilledIconButton(
                onClick = { submit(true) },
                enabled = enabled && !sending && draft.isNotEmpty(),
                modifier = Modifier.size(48.dp),
                shape = CircleShape,
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = UniTheme.colors.accent, contentColor = UniTheme.colors.onAccent, disabledContainerColor = UniTheme.colors.surfaceRaised, disabledContentColor = UniTheme.colors.muted),
            ) {
                if (sending) LoadingIndicator(Modifier.size(22.dp), color = UniTheme.colors.onAccent)
                else Icon(Icons.AutoMirrored.Rounded.Send, stringResource(R.string.terminal_send), Modifier.size(22.dp))
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (modifierLabel.isNotEmpty()) Text(
                stringResource(R.string.composer_modifiers, modifierLabel),
                Modifier.background(UniTheme.colors.accent.copy(alpha = .14f), CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall, color = UniTheme.colors.accent, fontWeight = FontWeight.Bold,
            )
            Text(stringResource(R.string.terminal_send_note), color = UniTheme.colors.muted, style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { submit(false) }, enabled = enabled && !sending && draft.isNotEmpty(), contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                Text(stringResource(R.string.terminal_send_raw), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}
