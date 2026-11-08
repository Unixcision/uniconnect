package com.unixcision.uniconnect.android.ui.design.arena

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DesktopMac
import androidx.compose.material.icons.rounded.FileUpload
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.ui.HomeDestination
import com.unixcision.uniconnect.android.ui.SettingsPage
import com.unixcision.uniconnect.android.ui.design.DrawerModel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Arena's side menu, set like a magazine's contents page: the masthead with how the machines are,
 * the sections under quiet small headings, and the version at the foot as the colophon.
 */
@Composable
fun ArenaDrawer(model: DrawerModel, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    val rule = colors.outline
    ModalDrawerSheet(
        modifier = Modifier.widthIn(max = 320.dp),
        drawerShape = RoundedCornerShape(topEnd = UniTheme.shapes.sheetRadius, bottomEnd = UniTheme.shapes.sheetRadius),
        drawerContainerColor = colors.surface,
        drawerContentColor = colors.text,
    ) {
        Column(Modifier.fillMaxHeight()) {
            Masthead(model, onClose = { onGo(HomeDestination.Machines) })
            Box(Modifier.padding(horizontal = 20.dp).fillMaxWidth().height(1.dp).background(rule))
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 12.dp)) {
                Group(stringResource(R.string.drawer_general), top = 10.dp)
                Entry(Icons.Rounded.DesktopMac, stringResource(R.string.drawer_machines), selected = true) { onGo(HomeDestination.Machines) }
                Entry(Icons.Rounded.FileUpload, stringResource(R.string.upload_title)) { onGo(HomeDestination.Files) }
                Entry(Icons.Rounded.History, stringResource(R.string.history_title), note = stringResource(R.string.home_shortcut_history)) {
                    onGo(HomeDestination.History)
                }

                Group(stringResource(R.string.drawer_notices))
                Entry(Icons.Rounded.NotificationsNone, stringResource(R.string.notices_title)) { onGo(HomeDestination.Notices) }

                Group(stringResource(R.string.settings))
                listOf(SettingsPage.APPEARANCE, SettingsPage.TERMINAL, SettingsPage.VOICE, SettingsPage.FILES, SettingsPage.CONNECTIONS).forEach { page ->
                    Entry(page.icon, stringResource(page.title)) { onGo(HomeDestination.Settings(page)) }
                }

                Group(stringResource(R.string.drawer_maintenance))
                Entry(SettingsPage.CLEANUP.icon, stringResource(SettingsPage.CLEANUP.title)) { onGo(HomeDestination.Settings(SettingsPage.CLEANUP)) }
                Entry(Icons.Rounded.BugReport, stringResource(R.string.drawer_diagnostics), marked = model.troubled) { onGo(HomeDestination.Diagnostics) }
            }
            Text(
                stringResource(R.string.settings_version, model.version),
                Modifier.fillMaxWidth()
                    .drawBehind { drawLine(rule, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }
                    .padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 20.dp),
                style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp), color = colors.muted,
            )
        }
    }
}

/** The mark, the name in the serif, the eyebrow and how many machines answer; the close on the right. */
@Composable
private fun Masthead(model: DrawerModel, onClose: () -> Unit) {
    val colors = UniTheme.colors
    val summary = model.summary
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 20.dp, bottom = 16.dp), verticalAlignment = Alignment.Top) {
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(40.dp).clip(UniTheme.shapes.chip))
        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                stringResource(R.string.app_name),
                style = MaterialTheme.typography.titleLarge.copy(fontSize = 21.sp, lineHeight = 26.sp, letterSpacing = (-0.2).sp),
                fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text(
                stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            ArenaDotLabel(
                stringResource(R.string.drawer_connected, summary.connected, summary.machines),
                if (summary.connected > 0) colors.success else colors.muted,
                Modifier.padding(top = 8.dp),
            )
        }
        // The machines are the page under the menu, so going there is closing it.
        IconButton(onClick = onClose, Modifier.offset(y = (-4).dp)) {
            Icon(Icons.Rounded.Close, stringResource(R.string.dismiss), tint = colors.muted)
        }
    }
}

/** A group's small heading, in capitals only where the theme sets labels that way. */
@Composable
private fun Group(title: String, top: Dp = 14.dp) {
    val type = UniTheme.type
    Text(
        if (type.labelUppercase) title.uppercase() else title,
        Modifier.padding(start = 20.dp, end = 20.dp, top = top, bottom = 6.dp),
        style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = type.labelLetterSpacing),
        fontWeight = FontWeight.SemiBold, color = UniTheme.colors.muted, maxLines = 1,
    )
}

/**
 * One entry: its icon, its name and an optional line under it. The current page sits on a sand
 * tile in semibold; a [marked] entry carries a dot in the warning colour.
 */
@Composable
private fun Entry(icon: ImageVector, label: String, selected: Boolean = false, note: String? = null, marked: Boolean = false, onClick: () -> Unit) {
    val colors = UniTheme.colors
    Row(
        Modifier.fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 1.dp)
            .clip(UniTheme.shapes.chip)
            .then(if (selected) Modifier.background(colors.surfaceRaised) else Modifier)
            .selectable(selected = selected, role = Role.Button, onClick = onClick)
            .heightIn(min = if (note != null) 52.dp else 44.dp)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(icon, null, Modifier.size(22.dp), tint = if (marked) colors.warning else if (selected) colors.text else colors.muted)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                label, style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 20.sp),
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = colors.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (note != null) Text(
                note, style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp),
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (marked) Box(Modifier.size(8.dp).background(colors.warning, CircleShape))
    }
}
