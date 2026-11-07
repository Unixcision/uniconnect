package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CleaningServices
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.SentMessageHistory
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Ajustes › Mensajes: cuántos mensajes enviados se guardan y cómo borrarlos todos, con una
 * confirmación porque no se pueden recuperar.
 */
@Composable
internal fun ColumnScope.SentMessagesSettingsSection(history: DictationHistoryViewModel) {
    val messages by history.sentMessages.collectAsStateWithLifecycle()
    val colors = UniTheme.colors
    var confirming by remember { mutableStateOf(false) }
    Text(
        stringResource(R.string.sent_settings_note, messages.size, SentMessageHistory.MAX_MESSAGES),
        style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
    )
    TextButton(
        onClick = { confirming = true },
        enabled = messages.isNotEmpty(),
        contentPadding = PaddingValues(horizontal = 0.dp, vertical = 0.dp),
        colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
    ) {
        Icon(Icons.Rounded.CleaningServices, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp))
        Text(stringResource(R.string.sent_clear), style = MaterialTheme.typography.labelLarge)
    }
    if (confirming) AlertDialog(
        onDismissRequest = { confirming = false },
        containerColor = colors.surfaceRaised,
        title = { Text(stringResource(R.string.sent_clear_confirm_title)) },
        confirmButton = { TextButton(onClick = { confirming = false; history.clearSent() }) { Text(stringResource(R.string.sent_clear_confirm), color = colors.danger) } },
        dismissButton = { TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.cancel)) } },
    )
}
