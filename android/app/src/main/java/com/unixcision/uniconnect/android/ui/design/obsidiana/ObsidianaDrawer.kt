package com.unixcision.uniconnect.android.ui.design.obsidiana

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.DesignTheme
import com.unixcision.uniconnect.android.ui.HomeDestination
import com.unixcision.uniconnect.android.ui.SettingsPage
import com.unixcision.uniconnect.android.ui.design.DrawerModel
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Obsidiana's side menu: dense rows under tracked violet groups, each with its value on the right
 * (how many machines, who waits, which design is on), and the version pinned at the foot.
 */
@Composable
fun ObsidianaDrawer(model: DrawerModel, onGo: (HomeDestination) -> Unit) {
    val colors = UniTheme.colors
    val summary = model.summary
    ModalDrawerSheet(
        modifier = Modifier.widthIn(max = 320.dp),
        drawerShape = RoundedCornerShape(topEnd = UniTheme.shapes.sheetRadius, bottomEnd = UniTheme.shapes.sheetRadius),
        drawerContainerColor = colors.surface,
        drawerContentColor = colors.text,
    ) {
        Column(Modifier.fillMaxHeight()) {
            Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())) {
                Row(
                    Modifier.fillMaxWidth().height(68.dp).padding(start = 16.dp, end = 6.dp, top = 12.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(32.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
                        Text(stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    // «Máquinas» is where the menu already is, so going there only closes it.
                    IconButton(onClick = { onGo(HomeDestination.Machines) }) {
                        Icon(Icons.Rounded.Close, stringResource(R.string.obsidiana_drawer_close), Modifier.size(18.dp), tint = colors.muted)
                    }
                }
                Row(
                    Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 12.dp).fillMaxWidth().height(40.dp)
                        .panel(UniTheme.shapes.chip, colors.background, colors.outline).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Dot(if (summary.connected > 0) colors.success else colors.muted)
                    Text(
                        stringResource(R.string.drawer_connected, summary.connected, summary.machines), Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        pluralStringResource(R.plurals.window_count, summary.windows, summary.windows), style = MaterialTheme.typography.bodySmall,
                        fontFamily = ObsidianaMono, fontSize = 11.sp, color = colors.muted, maxLines = 1,
                    )
                }
                Hairline()

                Group(stringResource(R.string.drawer_general))
                Entry(Icons.Rounded.Computer, stringResource(R.string.drawer_machines), current = true, onClick = { onGo(HomeDestination.Machines) }) {
                    Value(summary.machines.toString(), mono = true)
                }
                Entry(Icons.Rounded.Upload, stringResource(R.string.upload_title), onClick = { onGo(HomeDestination.Files) })
                Entry(Icons.Rounded.History, stringResource(R.string.history_title), note = stringResource(R.string.home_shortcut_history), onClick = { onGo(HomeDestination.History) })

                Group(stringResource(R.string.drawer_notices))
                Entry(Icons.Rounded.NotificationsNone, stringResource(R.string.notices_title), onClick = { onGo(HomeDestination.Notices) }) {
                    if (summary.waiting > 0) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Dot(colors.warning, size = 6.dp)
                        Value(summary.waiting.toString(), mono = true, tone = colors.warning)
                    }
                }

                Group(stringResource(R.string.settings))
                listOf(SettingsPage.APPEARANCE, SettingsPage.TERMINAL, SettingsPage.VOICE, SettingsPage.FILES, SettingsPage.CONNECTIONS).forEach { page ->
                    Entry(page.icon, stringResource(page.title), onClick = { onGo(HomeDestination.Settings(page)) }) {
                        if (page == SettingsPage.APPEARANCE) Value(stringResource(themeName(model.theme)))
                    }
                }

                Group(stringResource(R.string.drawer_maintenance))
                Entry(SettingsPage.CLEANUP.icon, stringResource(SettingsPage.CLEANUP.title), onClick = { onGo(HomeDestination.Settings(SettingsPage.CLEANUP)) })
                Entry(
                    Icons.Rounded.MonitorHeart, stringResource(R.string.drawer_diagnostics),
                    iconTone = if (model.troubled) colors.warning else null, onClick = { onGo(HomeDestination.Diagnostics) },
                ) {
                    if (model.troubled) Dot(colors.warning, size = 7.dp)
                }
                Spacer(Modifier.height(12.dp))
            }
            Hairline()
            Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(R.string.settings_version, model.version), style = MaterialTheme.typography.bodySmall,
                    fontFamily = ObsidianaMono, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** The visible name of a design. */
private fun themeName(theme: DesignTheme): Int = when (theme) {
    DesignTheme.NIEVE -> R.string.theme_nieve
    DesignTheme.OBSIDIANA -> R.string.theme_obsidiana
    DesignTheme.ARENA -> R.string.theme_arena
    DesignTheme.LIMA -> R.string.theme_lima
}

/** A group's title in tracked violet capitals. */
@Composable
private fun Group(title: String) {
    CapsLabel(title, Modifier.padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 6.dp))
}

/**
 * One entry: icon, name with an optional note under it, and its value on the right. The [current]
 * entry, where the menu stands, is raised and its icon takes the accent; [iconTone] overrides the icon when the entry has
 * news of its own.
 */
@Composable
private fun Entry(
    icon: ImageVector,
    label: String,
    current: Boolean = false,
    note: String? = null,
    iconTone: Color? = null,
    onClick: () -> Unit,
    value: @Composable () -> Unit = {},
) {
    val colors = UniTheme.colors
    val chipRadius = UniTheme.shapes.chipRadius
    // Inset eight points from the sheet, so the corner is a step smaller than a chip's.
    val shape = remember(chipRadius) { ContinuousRoundedShape(chipRadius - 2.dp) }
    Row(
        Modifier.padding(horizontal = 8.dp).fillMaxWidth().heightIn(min = if (note != null) 52.dp else 44.dp).clip(shape)
            .then(if (current) Modifier.background(colors.surfaceRaised) else Modifier)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { selected = current }
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, Modifier.size(18.dp), tint = iconTone ?: if (current) colors.accent else colors.muted)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                label, style = MaterialTheme.typography.bodyMedium, fontWeight = if (current) FontWeight.Medium else FontWeight.Normal,
                color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (note != null) Text(note, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        value()
    }
}

/** The value at the right of an entry: a count in mono, or a word in the muted colour. */
@Composable
private fun Value(text: String, mono: Boolean = false, tone: Color = UniTheme.colors.muted) {
    Text(
        text, style = MaterialTheme.typography.bodySmall, fontFamily = if (mono) ObsidianaMono else null,
        color = tone, maxLines = 1, softWrap = false,
    )
}
