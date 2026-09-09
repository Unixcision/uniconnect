package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowDownward
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.VerticalAlignTop
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.ui.components.SectionLabel

/** What a long press on a workspace or a window offers: favourite it and move it in its list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BoxActionsSheet(
    title: String,
    kind: Int,
    pinned: Boolean,
    onTogglePin: () -> Unit,
    onMoveTop: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = UniTheme.colors.surface) {
        Column(Modifier.padding(horizontal = 12.dp).padding(bottom = 28.dp)) {
            SectionLabel(stringResource(kind)) {}
            Text(title, Modifier.padding(horizontal = 8.dp, vertical = 6.dp), style = MaterialTheme.typography.titleLarge, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.height(6.dp))
            Action(if (pinned) R.string.box_unpin else R.string.box_pin, if (pinned) Icons.Rounded.Star else Icons.Rounded.StarBorder) { onTogglePin(); onDismiss() }
            Action(R.string.box_move_top, Icons.Rounded.VerticalAlignTop) { onMoveTop(); onDismiss() }
            Action(R.string.box_move_up, Icons.Rounded.ArrowUpward) { onMoveUp(); onDismiss() }
            Action(R.string.box_move_down, Icons.Rounded.ArrowDownward) { onMoveDown(); onDismiss() }
        }
    }
}

@Composable
private fun Action(label: Int, icon: ImageVector, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(stringResource(label)) },
        leadingContent = { Icon(icon, null, tint = UniTheme.colors.accent) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    )
}
