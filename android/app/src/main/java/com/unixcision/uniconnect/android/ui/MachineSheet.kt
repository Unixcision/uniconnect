package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint

/**
 * The machine form, used both to add and to edit.
 *
 * Saves an address only; connecting, reading and sending stay separate explicit actions. Passing
 * [machine] fills the fields with what is stored today, so correcting a host that changed IP or
 * port is an edit rather than a delete followed by a re-add.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun MachineSheet(
    saving: Boolean, error: Int?, machine: Machine? = null,
    onDismiss: () -> Unit, onSave: (String, String, String) -> Unit,
) {
    var name by rememberSaveable(machine?.id) { mutableStateOf(machine?.name.orEmpty()) }
    var address by rememberSaveable(machine?.id) { mutableStateOf(machine?.endpoint?.host.orEmpty()) }
    var port by rememberSaveable(machine?.id) { mutableStateOf((machine?.endpoint?.port ?: MachineEndpoint.DEFAULT_PORT).toString()) }
    ModalBottomSheet(
        onDismissRequest = { if (!saving) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = UniTheme.colors.surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = UniTheme.colors.outline) },
    ) {
        Column(Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SheetHeader(
                icon = { Icon(Icons.Rounded.Computer, null, tint = UniTheme.colors.accent) },
                title = stringResource(if (machine != null) R.string.edit_machine else R.string.add_machine),
                note = stringResource(R.string.machine_form_note), tone = UniTheme.colors.accent,
            )
            SheetField(name, { name = it }, stringResource(R.string.machine_name), enabled = !saving)
            SheetField(address, { address = it }, stringResource(R.string.machine_address), hint = stringResource(R.string.machine_address_hint), enabled = !saving, keyboard = KeyboardType.Uri)
            SheetField(port, { port = it }, stringResource(R.string.machine_port), enabled = !saving, keyboard = KeyboardType.Number)
            error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(onClick = { onSave(name, address, port) }, enabled = !saving, modifier = Modifier.fillMaxWidth(), shape = UniTheme.shapes.button, contentPadding = PaddingValues(16.dp)) {
                if (saving) LoadingIndicator(Modifier.size(20.dp), color = UniTheme.colors.onAccent) else Text(stringResource(R.string.save_machine), fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel), color = UniTheme.colors.muted) }
        }
    }
}

@Composable
fun SheetHeader(icon: @Composable () -> Unit, title: String, note: String, tone: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(46.dp).background(tone.copy(alpha = .14f), UniTheme.shapes.chip), contentAlignment = Alignment.Center) { icon() }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(note, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
        }
    }
}

@Composable
fun SheetField(
    value: String, onChange: (String) -> Unit, label: String, hint: String? = null, enabled: Boolean = true,
    keyboard: KeyboardType = KeyboardType.Text, placeholder: String? = null, monospace: Boolean = false,
) {
    OutlinedTextField(
        value, onChange, Modifier.fillMaxWidth(),
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it, color = UniTheme.colors.muted.copy(alpha = .6f)) } },
        supportingText = hint?.let { { Text(it) } },
        singleLine = true, enabled = enabled, shape = UniTheme.shapes.field,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = !monospace),
        textStyle = if (monospace) MaterialTheme.typography.bodyLarge.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace) else MaterialTheme.typography.bodyLarge,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = UniTheme.colors.accent, unfocusedBorderColor = UniTheme.colors.outline, focusedLabelColor = UniTheme.colors.accent,
            unfocusedLabelColor = UniTheme.colors.muted, cursorColor = UniTheme.colors.accent, focusedContainerColor = UniTheme.colors.surfaceRaised.copy(alpha = .5f),
            unfocusedContainerColor = UniTheme.colors.surfaceRaised.copy(alpha = .35f),
        ),
    )
}
