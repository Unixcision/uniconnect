package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** Where an entry of the side menu leads. */
sealed interface HomeDestination {
    data object Machines : HomeDestination
    data object Files : HomeDestination
    data object History : HomeDestination
    data object Notices : HomeDestination
    data class Settings(val page: SettingsPage) : HomeDestination
    data object Diagnostics : HomeDestination
}

/**
 * The side menu of the home: everything that is not a machine, divided by what it is for.
 * General (machines, files, history), notices, the pages of Ajustes and maintenance (cleanup and
 * the connection report), under a header that says how the machines are doing.
 */
@Composable
fun HomeDrawer(summary: HomeSummary, version: String, troubled: Boolean, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    ModalDrawerSheet(
        drawerContainerColor = colors.surface,
        drawerContentColor = colors.text,
        drawerShape = RoundedCornerShape(topEnd = UniTheme.shapes.sheetRadius, bottomEnd = UniTheme.shapes.sheetRadius),
        modifier = Modifier.widthIn(max = 320.dp),
    ) {
        Column(Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp, vertical = 18.dp)) {
            Row(Modifier.padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(42.dp))
                Column(Modifier.padding(start = 12.dp)) {
                    Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge, fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.labelMedium, color = colors.muted)
                }
            }
            Row(
                Modifier.padding(start = 10.dp, top = 14.dp, bottom = 6.dp).background(colors.accentSoft, UniTheme.shapes.chip).padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(Modifier.size(8.dp).background(if (summary.connected > 0) colors.success else colors.muted, CircleShape))
                Text(stringResource(R.string.drawer_connected, summary.connected, summary.machines), style = MaterialTheme.typography.labelMedium, color = colors.text)
            }

            DrawerGroup(stringResource(R.string.drawer_general))
            DrawerEntry(Icons.Rounded.Dns, stringResource(R.string.drawer_machines), selected = true) { onGo(HomeDestination.Machines) }
            DrawerEntry(Icons.Rounded.CloudUpload, stringResource(R.string.upload_title)) { onGo(HomeDestination.Files) }
            DrawerEntry(Icons.Rounded.History, stringResource(R.string.history_title)) { onGo(HomeDestination.History) }

            DrawerGroup(stringResource(R.string.drawer_notices))
            DrawerEntry(Icons.Rounded.NotificationsActive, stringResource(R.string.notices_title)) { onGo(HomeDestination.Notices) }

            DrawerGroup(stringResource(R.string.settings))
            listOf(SettingsPage.APPEARANCE, SettingsPage.TERMINAL, SettingsPage.VOICE, SettingsPage.FILES, SettingsPage.CONNECTIONS).forEach { page ->
                DrawerEntry(page.icon, stringResource(page.title)) { onGo(HomeDestination.Settings(page)) }
            }

            DrawerGroup(stringResource(R.string.drawer_maintenance))
            DrawerEntry(SettingsPage.CLEANUP.icon, stringResource(SettingsPage.CLEANUP.title)) { onGo(HomeDestination.Settings(SettingsPage.CLEANUP)) }
            DrawerEntry(Icons.Rounded.BugReport, stringResource(R.string.drawer_diagnostics), badge = troubled) { onGo(HomeDestination.Diagnostics) }

            Spacer(Modifier.height(24.dp))
            Text(
                stringResource(R.string.settings_version, version),
                Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelSmall, color = colors.muted,
            )
        }
    }
}

@Composable
private fun DrawerGroup(title: String) {
    Text(
        if (UniTheme.type.labelUppercase) title.uppercase() else title,
        Modifier.padding(start = 12.dp, top = 22.dp, bottom = 6.dp),
        style = MaterialTheme.typography.labelSmall,
        color = UniTheme.colors.muted,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = UniTheme.type.labelLetterSpacing,
    )
}

@Composable
private fun DrawerEntry(icon: ImageVector, label: String, selected: Boolean = false, badge: Boolean = false, onClick: () -> Unit) {
    val colors = UniTheme.colors
    NavigationDrawerItem(
        label = { Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal) },
        icon = { Icon(icon, null) },
        badge = if (badge) ({ Box(Modifier.size(8.dp).background(colors.warning, CircleShape)) }) else null,
        selected = selected,
        onClick = onClick,
        shape = UniTheme.shapes.button,
        colors = NavigationDrawerItemDefaults.colors(
            selectedContainerColor = colors.accentSoft,
            unselectedContainerColor = colors.surface,
            selectedIconColor = colors.accent,
            unselectedIconColor = colors.muted,
            selectedTextColor = colors.accent,
            unselectedTextColor = colors.text,
        ),
        modifier = Modifier.height(48.dp),
    )
}
