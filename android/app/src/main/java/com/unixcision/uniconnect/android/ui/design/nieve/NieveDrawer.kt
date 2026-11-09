package com.unixcision.uniconnect.android.ui.design.nieve

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Upgrade
import com.unixcision.uniconnect.android.domain.RelaunchVerb
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
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

/** How far the drawer's groups sit from its edges: tighter than a page, the sheet is narrow. */
private val DRAWER_MARGIN = 12.dp

/** Where the hairline between two entries starts: past the icon, under the label. */
private val ENTRY_RULE = 48.dp

/**
 * Nieve's side menu, a grouped list like the first page of Apple's Settings: the brand and how
 * many machines answer, then General, Notificaciones, Ajustes and Mantenimiento, each a white
 * block of rows on the grey sheet, with the value an entry holds on its right.
 */
@Composable
fun NieveDrawer(model: DrawerModel, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    val radius = UniTheme.shapes.sheetRadius
    ModalDrawerSheet(
        modifier = Modifier.widthIn(max = 320.dp),
        drawerShape = RoundedCornerShape(topEnd = radius, bottomEnd = radius),
        drawerContainerColor = colors.background,
        drawerContentColor = colors.text,
    ) {
        Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 22.dp)) {
            Row(
                Modifier.padding(horizontal = 16.dp).heightIn(min = 52.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(40.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.app_name), style = NieveText.headline.copy(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Bold),
                        fontFamily = UniTheme.type.headlineFamily, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text(stringResource(R.string.home_eyebrow), style = NieveText.detail, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            Row(
                Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                NieveDot(if (model.summary.connected > 0) colors.success else colors.muted)
                Text(
                    stringResource(R.string.drawer_connected, model.summary.connected, model.summary.machines),
                    style = NieveText.body.copy(fontSize = 14.sp), fontWeight = FontWeight.Medium, maxLines = 1,
                )
            }

            NieveHeader(stringResource(R.string.drawer_general), margin = DRAWER_MARGIN, top = 14.dp)
            EntryGroup(
                listOf(
                    MenuEntry(Icons.Rounded.Computer, stringResource(R.string.drawer_machines), HomeDestination.Machines, current = true),
                    MenuEntry(Icons.Rounded.Upload, stringResource(R.string.upload_title), HomeDestination.Files),
                    MenuEntry(Icons.Rounded.History, stringResource(R.string.history_title), HomeDestination.History, value = stringResource(R.string.nieve_history_note)),
                ),
                onGo,
            )

            NieveHeader(stringResource(R.string.drawer_notices), margin = DRAWER_MARGIN, top = 18.dp)
            EntryGroup(listOf(MenuEntry(Icons.Rounded.Notifications, stringResource(R.string.notices_title), HomeDestination.Notices)), onGo)

            NieveHeader(stringResource(R.string.settings), margin = DRAWER_MARGIN, top = 18.dp)
            val themeName = stringResource(
                when (model.theme) {
                    DesignTheme.NIEVE -> R.string.theme_nieve
                    DesignTheme.OBSIDIANA -> R.string.theme_obsidiana
                    DesignTheme.ARENA -> R.string.theme_arena
                    DesignTheme.LIMA -> R.string.theme_lima
                },
            )
            EntryGroup(
                listOf(SettingsPage.APPEARANCE, SettingsPage.TERMINAL, SettingsPage.VOICE, SettingsPage.FILES, SettingsPage.CONNECTIONS).map { page ->
                    MenuEntry(page.icon, stringResource(page.title), HomeDestination.Settings(page), value = themeName.takeIf { page == SettingsPage.APPEARANCE })
                },
                onGo,
            )

            NieveHeader(stringResource(R.string.drawer_maintenance), margin = DRAWER_MARGIN, top = 18.dp)
            EntryGroup(
                listOfNotNull(
                    MenuEntry(Icons.Rounded.RestartAlt, stringResource(R.string.relaunch_everywhere), HomeDestination.Everywhere(RelaunchVerb.RELAUNCH))
                        .takeIf { model.relaunchesEverywhere },
                    MenuEntry(Icons.Rounded.Upgrade, stringResource(R.string.update_everywhere), HomeDestination.Everywhere(RelaunchVerb.UPDATE))
                        .takeIf { model.updatesEverywhere },
                    MenuEntry(SettingsPage.CLEANUP.icon, stringResource(SettingsPage.CLEANUP.title), HomeDestination.Settings(SettingsPage.CLEANUP)),
                    MenuEntry(Icons.Rounded.BugReport, stringResource(R.string.drawer_diagnostics), HomeDestination.Diagnostics, flagged = model.troubled),
                ),
                onGo,
            )

            Text(
                stringResource(R.string.settings_version, model.version),
                Modifier.padding(start = DRAWER_MARGIN + 16.dp, end = DRAWER_MARGIN + 16.dp, top = 24.dp),
                style = NieveText.detail, color = colors.muted,
            )
        }
    }
}

/** One entry of the menu: where it leads, and what it shows on its right, if anything. */
private class MenuEntry(
    val icon: ImageVector,
    val label: String,
    val destination: HomeDestination,
    /** The page on screen behind the menu: tinted, and read out as selected. */
    val current: Boolean = false,
    val value: String? = null,
    /** Something to look at: a warning dot at the end of the row. */
    val flagged: Boolean = false,
)

/** A white block of entries split by hairlines that start under the labels. */
@Composable
private fun EntryGroup(entries: List<MenuEntry>, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    Column(Modifier.nieveGroup(margin = DRAWER_MARGIN)) {
        entries.forEachIndexed { index, entry ->
            NieveRow(
                Modifier.semantics { selected = entry.current },
                rule = if (index > 0) ENTRY_RULE else null, minHeight = 48.dp,
                padding = PaddingValues(start = 16.dp, end = 14.dp),
                highlight = if (entry.current) colors.accentSoft else null,
                onClick = { onGo(entry.destination) },
            ) {
                Icon(entry.icon, null, Modifier.size(20.dp), tint = colors.accent)
                Text(
                    entry.label, Modifier.weight(1f), style = NieveText.menu,
                    fontWeight = if (entry.current) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (entry.current) colors.accent else colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (entry.value != null) Text(entry.value, style = NieveText.detail, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (entry.flagged) NieveDot(colors.warning)
            }
        }
    }
}
