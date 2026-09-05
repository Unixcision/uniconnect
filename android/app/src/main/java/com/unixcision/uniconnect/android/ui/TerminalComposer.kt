package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R

/** A draft stays local until an explicit send, and is cleared only after host acknowledgement. */
@Composable
fun TerminalComposer(
    enabled: Boolean,
    sending: Boolean,
    onSend: (String, (Boolean) -> Unit) -> Unit,
) {
    var draft by rememberSaveable { mutableStateOf("") }
    var showKeys by rememberSaveable { mutableStateOf(false) }
    val submit: (Boolean) -> Unit = { withEnter ->
        if (enabled && !sending && draft.isNotEmpty()) {
            val submitted = draft
            // One request owns text plus Enter. Never replay it after an uncertain delivery.
            onSend(submitted + if (withEnter) "\r" else "") { delivered ->
                if (delivered && draft == submitted) draft = ""
            }
        }
    }
    Column(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 8.dp)) {
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = Brand.Surface,
            border = BorderStroke(1.dp, Brand.Outline),
        ) {
            Row(Modifier.fillMaxWidth().padding(6.dp), verticalAlignment = Alignment.Bottom) {
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp, vertical = 12.dp),
                    enabled = !sending,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = Brand.Text),
                    cursorBrush = SolidColor(Brand.Cyan),
                    minLines = 1,
                    maxLines = 6,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { submit(true) }),
                    decorationBox = { field ->
                        Box {
                            if (draft.isEmpty()) Text(stringResource(R.string.terminal_input), color = Brand.Muted)
                            field()
                        }
                    },
                )
                FilledIconButton(
                    onClick = { submit(true) },
                    enabled = enabled && !sending && draft.isNotEmpty(),
                    modifier = Modifier.size(48.dp),
                ) {
                    if (sending) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Icon(Icons.Rounded.ArrowUpward, stringResource(R.string.terminal_send))
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { showKeys = !showKeys }, contentPadding = PaddingValues(horizontal = 8.dp)) {
                Icon(Icons.Rounded.Keyboard, null, Modifier.size(18.dp), tint = Brand.Muted)
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.terminal_keys), color = Brand.Muted, style = MaterialTheme.typography.labelMedium)
            }
            Spacer(Modifier.weight(1f))
            Text(stringResource(R.string.terminal_send_note), Modifier.padding(end = 8.dp), color = Brand.Muted, style = MaterialTheme.typography.labelSmall)
        }
        if (showKeys) Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            listOf(
                R.string.terminal_escape to "\u001b",
                R.string.terminal_tab to "\t",
                R.string.terminal_enter to "\r",
                R.string.terminal_up to "\u001b[A",
                R.string.terminal_down to "\u001b[B",
                R.string.terminal_interrupt to "\u0003",
            ).forEach { (label, key) ->
                TextButton(onClick = { onSend(key) {} }, enabled = enabled && !sending) {
                    Text(stringResource(label), style = MaterialTheme.typography.labelMedium)
                }
            }
            TextButton(onClick = { submit(false) }, enabled = enabled && !sending && draft.isNotEmpty()) {
                Text(stringResource(R.string.terminal_send_raw), style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}
