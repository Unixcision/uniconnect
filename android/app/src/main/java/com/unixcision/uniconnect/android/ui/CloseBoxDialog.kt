package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * The one confirmation before closing a workspace or a window (`box-close.v1`). The machine does
 * not ask again, so this is where the reader is told it goes on the desktop too and, for a
 * workspace, how many windows go with it.
 *
 * @param windowCount the workspace's windows, or null when one window is being closed.
 */
@Composable
fun CloseBoxDialog(name: String, machineName: String, windowCount: Int?, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.box_close_confirm_title, name, machineName)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(stringResource(R.string.box_close_confirm_note), style = MaterialTheme.typography.bodyMedium)
                if (windowCount != null && windowCount > 0) {
                    Text(
                        pluralStringResource(R.plurals.box_close_confirm_windows, windowCount, windowCount),
                        style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.warning,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.close), color = UniTheme.colors.danger, fontWeight = FontWeight.SemiBold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = UniTheme.colors.surface,
    )
}
