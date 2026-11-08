package com.unixcision.uniconnect.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.Greeting
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.components.BoxMonogram
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.components.PillTone
import com.unixcision.uniconnect.android.ui.components.SectionLabel
import com.unixcision.uniconnect.android.ui.components.StatusPill
import com.unixcision.uniconnect.android.ui.components.themedTone
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.util.Calendar

/** The home's bar: the side menu on the left, refresh and «Añadir máquina» on the right. */
@Composable
fun HomeTopBar(refreshing: Boolean, troubled: Boolean, onMenu: () -> Unit, onRefresh: () -> Unit, onDiagnostics: () -> Unit, onAdd: () -> Unit) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onMenu) { Icon(Icons.Rounded.Menu, stringResource(R.string.drawer_open), tint = colors.text) }
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.padding(start = 2.dp).size(30.dp))
        Text(
            stringResource(R.string.app_name), Modifier.weight(1f).padding(start = 10.dp),
            style = MaterialTheme.typography.titleMedium, fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
        )
        // Only when there is something to tell: several failures in a row, not a reconnect blink.
        if (troubled) IconButton(onClick = onDiagnostics) { Icon(Icons.Rounded.BugReport, stringResource(R.string.diagnostics_open), tint = colors.warning) }
        IconButton(onClick = onRefresh, enabled = !refreshing) {
            if (refreshing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
            else Icon(Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), tint = colors.muted)
        }
        FilledIconButton(
            onClick = onAdd,
            shape = UniTheme.shapes.button,
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) { Icon(Icons.Rounded.Add, stringResource(R.string.add_machine)) }
    }
}

/**
 * The home: a greeting with how things are, three numbers that matter (machines that answer, AIs
 * working, AIs waiting for the reader), the machines with what their AIs are doing, and the ways
 * into everything else. Each theme dresses it with its own colours, shapes and type.
 */
@Composable
fun HomeDashboard(
    machines: List<Machine>,
    summaries: Map<String, HomeSummary>,
    states: Map<String, MachineState>,
    onSelect: (String) -> Unit,
    onAdd: () -> Unit,
    onFiles: () -> Unit,
    onHistory: () -> Unit,
    onNotices: () -> Unit,
    onSettings: () -> Unit,
) {
    val spacing = UniTheme.spacing
    val colors = UniTheme.colors
    val total = remember(summaries, machines) { HomeSummary.total(machines.map { summaries[it.id] ?: HomeSummary(1, 0, 0, 0, 0) }) }
    val greeting = remember { Greeting.at(Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) }
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = spacing.page, end = spacing.page, top = 8.dp, bottom = 40.dp),
        verticalArrangement = Arrangement.spacedBy(spacing.gap),
    ) {
        item {
            Column(Modifier.padding(top = 6.dp, bottom = 4.dp)) {
                Text(
                    stringResource(when (greeting) { Greeting.MORNING -> R.string.home_greeting_morning; Greeting.AFTERNOON -> R.string.home_greeting_afternoon; Greeting.NIGHT -> R.string.home_greeting_night }),
                    style = MaterialTheme.typography.headlineLarge, fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
                )
                Text(
                    if (machines.isEmpty()) stringResource(R.string.home_subtitle)
                    else stringResource(R.string.home_summary_line, total.connected, total.machines, pluralStringResource(R.plurals.window_count, total.windows, total.windows)),
                    Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyLarge, color = colors.muted,
                )
            }
        }
        if (machines.isNotEmpty()) item {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
                StatTile("${total.connected}/${total.machines}", stringResource(R.string.home_stat_connected), colors.success, null, Modifier.weight(1f).fillMaxHeight())
                StatTile(total.working.toString(), stringResource(R.string.home_stat_working), colors.accent, ActivityState.WORKING.takeIf { total.working > 0 }, Modifier.weight(1f).fillMaxHeight())
                StatTile(total.waiting.toString(), stringResource(R.string.home_stat_waiting), colors.warning, ActivityState.WAITING.takeIf { total.waiting > 0 }, Modifier.weight(1f).fillMaxHeight())
            }
        }
        item { SectionLabel(stringResource(R.string.home_title), Modifier.padding(top = 10.dp)) }
        if (machines.isEmpty()) item {
            GlassCard(Modifier.fillMaxWidth(), accent = colors.accent) {
                Column(Modifier.padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(96.dp))
                    Text(stringResource(R.string.empty_title), Modifier.padding(top = 16.dp), style = MaterialTheme.typography.titleLarge, fontFamily = UniTheme.type.headlineFamily)
                    Text(stringResource(R.string.empty_detail), Modifier.padding(top = 8.dp), color = colors.muted, style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = onAdd, modifier = Modifier.fillMaxWidth().padding(top = 22.dp), shape = UniTheme.shapes.button, contentPadding = PaddingValues(16.dp)) {
                        Icon(Icons.Rounded.Add, null, Modifier.size(20.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
        machines.forEach { machine ->
            item(key = machine.id) {
                key(machine.id) { MachineCard(machine, summaries[machine.id], states[machine.id] ?: MachineState.SAVED) { onSelect(machine.id) } }
            }
        }
        item { SectionLabel(stringResource(R.string.home_shortcuts), Modifier.padding(top = 10.dp)) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
                Row(horizontalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
                    ShortcutTile(Icons.Rounded.CloudUpload, stringResource(R.string.upload_title), stringResource(R.string.home_shortcut_files), Modifier.weight(1f), onFiles)
                    ShortcutTile(Icons.Rounded.History, stringResource(R.string.history_title), stringResource(R.string.home_shortcut_history), Modifier.weight(1f), onHistory)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(spacing.gapSmall)) {
                    ShortcutTile(Icons.Rounded.NotificationsActive, stringResource(R.string.notices_title), stringResource(R.string.home_shortcut_notices), Modifier.weight(1f), onNotices)
                    ShortcutTile(Icons.Rounded.Tune, stringResource(R.string.settings), stringResource(R.string.home_shortcut_settings), Modifier.weight(1f), onSettings)
                }
            }
        }
        item {
            Row(Modifier.padding(top = 14.dp, start = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(28.dp).background(colors.success.copy(alpha = .12f), CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Shield, null, Modifier.size(15.dp), tint = colors.success)
                }
                Text(stringResource(R.string.security_note), style = MaterialTheme.typography.bodySmall, color = colors.muted)
            }
        }
    }
}

/** How a machine's card shows its link. */
enum class MachineState { CONNECTED, CHECKING, SAVED }

/** One number that matters, big, with what it counts underneath. */
@Composable
private fun StatTile(value: String, label: String, tone: Color, activity: ActivityState?, modifier: Modifier) {
    GlassCard(modifier, accent = tone) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(value, style = MaterialTheme.typography.headlineMedium, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold, color = tone)
                if (activity != null) ActivityMark(activity, size = 16.dp, tone = tone)
            }
            Text(label, style = MaterialTheme.typography.labelMedium, color = UniTheme.colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A saved machine: who it is, whether it answers and what its AIs are doing right now. */
@Composable
private fun MachineCard(machine: Machine, summary: HomeSummary?, state: MachineState, onSelect: () -> Unit) {
    val colors = UniTheme.colors
    val identifier = UniTheme.type.identifierFamily
    val tone = themedTone(machine.name)
    GlassCard(Modifier.fillMaxWidth(), accent = if (state == MachineState.CONNECTED) colors.success else tone, onClick = onSelect, style = UniTheme.layout.rowsAs) {
        Column(Modifier.fillMaxWidth().padding(UniTheme.layout.cardPadding), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BoxMonogram(machine.name, size = 48.dp, selected = state == MachineState.CONNECTED, tone = tone)
                Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                    Text(machine.name, style = MaterialTheme.typography.titleMedium, fontFamily = identifier, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(machine.endpoint.displayAddress, color = colors.muted, style = MaterialTheme.typography.bodySmall, fontFamily = identifier, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, tint = colors.muted)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                when (state) {
                    MachineState.CONNECTED -> StatusPill(stringResource(R.string.connected_machine), PillTone.Live)
                    MachineState.CHECKING -> StatusPill(stringResource(R.string.checking_machine), PillTone.Busy)
                    MachineState.SAVED -> StatusPill(stringResource(R.string.saved_machine), PillTone.Idle)
                }
                if (summary != null && summary.windows > 0) {
                    Text(pluralStringResource(R.plurals.window_count, summary.windows, summary.windows), style = MaterialTheme.typography.labelMedium, color = colors.muted)
                }
                Spacer(Modifier.weight(1f))
                if (summary != null && summary.working > 0) ActivityCount(ActivityState.WORKING, summary.working, colors.accent)
                if (summary != null && summary.waiting > 0) ActivityCount(ActivityState.WAITING, summary.waiting, colors.warning)
            }
        }
    }
}

@Composable
private fun ActivityCount(state: ActivityState, count: Int, tone: Color) {
    Row(
        Modifier.background(tone.copy(alpha = .12f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        ActivityMark(state, size = 13.dp, tone = tone)
        Text(count.toString(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = tone, fontFamily = UniTheme.type.identifierFamily)
    }
}

/** A way into something that is not a machine: an icon, a name and one line of what it is. */
@Composable
private fun ShortcutTile(icon: ImageVector, title: String, note: String, modifier: Modifier, onClick: () -> Unit) {
    val colors = UniTheme.colors
    GlassCard(modifier, onClick = onClick) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(38.dp).background(colors.accentSoft, UniTheme.shapes.chip), contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(20.dp), tint = colors.accent)
            }
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(note, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}
