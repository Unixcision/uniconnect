package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import com.unixcision.uniconnect.android.domain.MachineEndpoint

/** Saves an address only; connecting, reading and sending stay separate explicit actions. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun AddMachineSheet(saving: Boolean, error: Int?, onDismiss: () -> Unit, onSave: (String, String, String) -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var address by rememberSaveable { mutableStateOf("") }
    var port by rememberSaveable { mutableStateOf(MachineEndpoint.DEFAULT_PORT.toString()) }
    ModalBottomSheet(
        onDismissRequest = { if (!saving) onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Brand.Surface,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Brand.Outline) },
    ) {
        Column(Modifier.padding(horizontal = 24.dp).verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            SheetHeader(icon = { Icon(Icons.Rounded.Computer, null, tint = Brand.Cyan) }, title = stringResource(R.string.add_machine), note = stringResource(R.string.machine_form_note), tone = Brand.Cyan)
            SheetField(name, { name = it }, stringResource(R.string.machine_name), enabled = !saving)
            SheetField(address, { address = it }, stringResource(R.string.machine_address), hint = stringResource(R.string.machine_address_hint), enabled = !saving, keyboard = KeyboardType.Uri)
            SheetField(port, { port = it }, stringResource(R.string.machine_port), enabled = !saving, keyboard = KeyboardType.Number)
            error?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Button(onClick = { onSave(name, address, port) }, enabled = !saving, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(18.dp), contentPadding = PaddingValues(16.dp)) {
                if (saving) LoadingIndicator(Modifier.size(20.dp), color = Brand.Night) else Text(stringResource(R.string.save_machine), fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = onDismiss, enabled = !saving, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel), color = Brand.Muted) }
        }
    }
}

@Composable
fun SheetHeader(icon: @Composable () -> Unit, title: String, note: String, tone: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(46.dp).background(tone.copy(alpha = .14f), RoundedCornerShape(15.dp)), contentAlignment = Alignment.Center) { icon() }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(note, style = MaterialTheme.typography.bodySmall, color = Brand.Muted)
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
        placeholder = placeholder?.let { { Text(it, color = Brand.Muted.copy(alpha = .6f)) } },
        supportingText = hint?.let { { Text(it) } },
        singleLine = true, enabled = enabled, shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboard, autoCorrectEnabled = !monospace),
        textStyle = if (monospace) MaterialTheme.typography.bodyLarge.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace) else MaterialTheme.typography.bodyLarge,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Brand.Cyan, unfocusedBorderColor = Brand.Outline, focusedLabelColor = Brand.Cyan,
            unfocusedLabelColor = Brand.Muted, cursorColor = Brand.Cyan, focusedContainerColor = Brand.DeepBlue.copy(alpha = .5f),
            unfocusedContainerColor = Brand.DeepBlue.copy(alpha = .35f),
        ),
    )
}
