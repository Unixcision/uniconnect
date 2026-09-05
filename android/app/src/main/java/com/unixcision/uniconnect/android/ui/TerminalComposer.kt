package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowUpward
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
    onSend: (String, (Boolean) -> Unit) -> Unit,
) {
    var draft by rememberSaveable { mutableStateOf("") }
    val submit: (Boolean) -> Unit = { withEnter ->
        if (enabled && !sending && draft.isNotEmpty()) {
            val submitted = draft
            // One request owns text plus Enter. Never replay it after an uncertain delivery.
            onSend(TerminalKeyEncoder.encodeText(submitted, modifiers) + if (withEnter) "\r" else "") { delivered ->
                if (delivered && draft == submitted) draft = ""
            }
        }
    }
    val modifierLabel = listOfNotNull(
        stringResource(R.string.key_ctrl).takeIf { modifiers.ctrl },
        stringResource(R.string.key_alt).takeIf { modifiers.alt },
    ).joinToString("+")
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalIconButton(onClick = onToggleKeys, modifier = Modifier.size(48.dp), colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Brand.DeepBlue, contentColor = Brand.Muted)) {
                Icon(if (keysVisible) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard, stringResource(if (keysVisible) R.string.keys_hide else R.string.keys_show))
            }
            Row(
                Modifier.weight(1f).background(Brand.Surface, RoundedCornerShape(24.dp))
                    .border(1.dp, Brush.linearGradient(listOf(Brand.GlassTop, Brand.GlassBottom)), RoundedCornerShape(24.dp))
                    .padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.weight(1f).padding(vertical = 10.dp),
                    enabled = !sending,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = Brand.Text, fontFamily = FontFamily.Monospace),
                    cursorBrush = SolidColor(Brand.Cyan),
                    minLines = 1,
                    maxLines = 6,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { submit(true) }),
                    decorationBox = { field ->
                        Box {
                            if (draft.isEmpty()) Text(stringResource(R.string.terminal_input), color = Brand.Muted, style = MaterialTheme.typography.bodyLarge)
                            field()
                        }
                    },
                )
                FilledIconButton(
                    onClick = { submit(true) },
                    enabled = enabled && !sending && draft.isNotEmpty(),
                    modifier = Modifier.size(36.dp),
                    colors = IconButtonDefaults.filledIconButtonColors(containerColor = Brand.Cyan, contentColor = Brand.Night, disabledContainerColor = Brand.DeepBlue, disabledContentColor = Brand.Muted),
                ) {
                    if (sending) LoadingIndicator(Modifier.size(18.dp), color = Brand.Night)
                    else Icon(Icons.Rounded.ArrowUpward, stringResource(R.string.terminal_send), Modifier.size(18.dp))
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp, start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (modifierLabel.isNotEmpty()) Text(
                stringResource(R.string.composer_modifiers, modifierLabel),
                Modifier.background(Brand.Cyan.copy(alpha = .14f), CircleShape).padding(horizontal = 10.dp, vertical = 3.dp),
                style = MaterialTheme.typography.labelSmall, color = Brand.Cyan, fontWeight = FontWeight.Bold,
            )
            Text(stringResource(R.string.terminal_send_note), color = Brand.Muted, style = MaterialTheme.typography.labelSmall)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { submit(false) }, enabled = enabled && !sending && draft.isNotEmpty(), contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp)) {
                Text(stringResource(R.string.terminal_send_raw), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}
