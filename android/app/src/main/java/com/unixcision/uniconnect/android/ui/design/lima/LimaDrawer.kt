package com.unixcision.uniconnect.android.ui.design.lima

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Upgrade
import com.unixcision.uniconnect.android.domain.RelaunchVerb
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.ui.HomeDestination
import com.unixcision.uniconnect.android.ui.SettingsPage
import com.unixcision.uniconnect.android.ui.design.DrawerModel
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Lima's side menu, in the home's language: the brand, a chip with how many machines answer, and
 * the entries in one block per group, the current one filled with lime. Small chips on the right
 * say what an entry holds: how many machines, which design is in force.
 */
@Composable
fun LimaDrawer(model: DrawerModel, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    val themeName = stringResource(
        when (model.theme) {
            DesignTheme.NIEVE -> R.string.theme_nieve
            DesignTheme.OBSIDIANA -> R.string.theme_obsidiana
            DesignTheme.ARENA -> R.string.theme_arena
            DesignTheme.LIMA -> R.string.theme_lima
        },
    )
    ModalDrawerSheet(
        modifier = Modifier.widthIn(max = 320.dp),
        drawerShape = RoundedCornerShape(topEnd = UniTheme.shapes.sheetRadius, bottomEnd = UniTheme.shapes.sheetRadius),
        drawerContainerColor = colors.surface,
        drawerContentColor = colors.text,
    ) {
        Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 18.dp)) {
            Row(Modifier.fillMaxWidth().padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(40.dp))
                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                    Text(
                        stringResource(R.string.app_name), style = MaterialTheme.typography.titleMedium, fontSize = 18.sp,
                        fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text(stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                // The host closes the menu on any destination; the machines are where the reader already is.
                LimaSquareButton(Icons.Rounded.Close, stringResource(R.string.lima_drawer_close), { onGo(HomeDestination.Machines) }, fill = colors.surfaceRaised)
            }
            Row(
                Modifier.padding(start = 4.dp, top = 12.dp).background(colors.surfaceRaised, UniTheme.shapes.chip).padding(horizontal = 10.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(7.dp).background(if (model.summary.connected > 0) colors.accent else colors.muted, CircleShape))
                Text(
                    stringResource(R.string.drawer_connected, model.summary.connected, model.summary.machines),
                    style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Medium,
                )
            }

            LimaDrawerGroup(stringResource(R.string.drawer_general)) {
                LimaDrawerEntry(Icons.Rounded.Computer, stringResource(R.string.drawer_machines), selected = true, value = model.summary.machines.toString()) {
                    onGo(HomeDestination.Machines)
                }
                LimaDrawerEntry(Icons.Rounded.CloudUpload, stringResource(R.string.upload_title)) { onGo(HomeDestination.Files) }
                LimaDrawerEntry(Icons.Rounded.History, stringResource(R.string.history_title), note = stringResource(R.string.home_shortcut_history)) {
                    onGo(HomeDestination.History)
                }
            }
            LimaDrawerGroup(stringResource(R.string.drawer_notices)) {
                LimaDrawerEntry(Icons.Rounded.NotificationsActive, stringResource(R.string.notices_title)) { onGo(HomeDestination.Notices) }
            }
            LimaDrawerGroup(stringResource(R.string.settings)) {
                listOf(SettingsPage.APPEARANCE, SettingsPage.TERMINAL, SettingsPage.VOICE, SettingsPage.FILES, SettingsPage.CONNECTIONS).forEach { page ->
                    LimaDrawerEntry(page.icon, stringResource(page.title), value = themeName.takeIf { page == SettingsPage.APPEARANCE }) {
                        onGo(HomeDestination.Settings(page))
                    }
                }
            }
            LimaDrawerGroup(stringResource(R.string.drawer_maintenance)) {
                if (model.relaunchesEverywhere) LimaDrawerEntry(Icons.Rounded.RestartAlt, stringResource(R.string.relaunch_everywhere)) {
                    onGo(HomeDestination.Everywhere(RelaunchVerb.RELAUNCH))
                }
                if (model.updatesEverywhere) LimaDrawerEntry(Icons.Rounded.Upgrade, stringResource(R.string.update_everywhere)) {
                    onGo(HomeDestination.Everywhere(RelaunchVerb.UPDATE))
                }
                LimaDrawerEntry(SettingsPage.CLEANUP.icon, stringResource(SettingsPage.CLEANUP.title)) { onGo(HomeDestination.Settings(SettingsPage.CLEANUP)) }
                LimaDrawerEntry(Icons.Rounded.BugReport, stringResource(R.string.drawer_diagnostics), flagged = model.troubled) { onGo(HomeDestination.Diagnostics) }
            }

            Text(
                stringResource(R.string.settings_version, model.version),
                Modifier.padding(start = 10.dp, top = 20.dp), style = MaterialTheme.typography.labelMedium, color = colors.muted,
            )
        }
    }
}

/** A group: its eyebrow, then its entries on one raised block. */
@Composable
private fun LimaDrawerGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    LimaEyebrow(title, Modifier.padding(start = 10.dp, top = 16.dp, bottom = 6.dp))
    Column(
        Modifier.fillMaxWidth().clip(UniTheme.shapes.card).background(UniTheme.colors.surfaceRaised).padding(6.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        content = content,
    )
}

/**
 * One entry: icon, label and an optional note under it; on the right a chip with a value, or a
 * warning dot when the entry has something to tell. The current entry is filled with lime.
 */
@Composable
private fun LimaDrawerEntry(
    icon: ImageVector,
    label: String,
    selected: Boolean = false,
    note: String? = null,
    value: String? = null,
    flagged: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = UniTheme.colors
    val ink = if (selected) colors.onAccent else colors.text
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(UniTheme.shapes.button)
            .then(if (selected) Modifier.background(colors.accent) else Modifier)
            .selectable(selected = selected, role = Role.Button, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = if (selected) colors.onAccent else colors.muted)
        Column(Modifier.weight(1f)) {
            Text(
                label, style = MaterialTheme.typography.bodyLarge, fontSize = 15.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (note != null) Text(
                note, style = MaterialTheme.typography.bodySmall, color = if (selected) ink.copy(alpha = .7f) else colors.muted,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        if (flagged) Box(Modifier.size(8.dp).background(colors.warning, CircleShape))
        if (value != null) Text(
            value,
            Modifier.background(if (selected) ink.copy(alpha = .14f) else colors.surface, UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
            style = MaterialTheme.typography.labelMedium, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold,
            color = if (selected) ink else colors.muted, maxLines = 1,
        )
    }
}
