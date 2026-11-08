package com.unixcision.uniconnect.android.ui.design.arena

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityItem
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AgentLabel
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.components.GlassCard
import com.unixcision.uniconnect.android.ui.design.HomeActions
import com.unixcision.uniconnect.android.ui.design.HomeMachine
import com.unixcision.uniconnect.android.ui.design.HomeModel
import com.unixcision.uniconnect.android.ui.design.elapsedText
import com.unixcision.uniconnect.android.ui.design.greetingText
import com.unixcision.uniconnect.android.ui.design.todayText
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** How many waiting windows lead the timeline; the rest are counted under it. */
private const val WAITING_SHOWN = 3

/** A number that cannot be known: what a machine's AIs do while it does not answer. */
private const val UNKNOWN_FIGURE = "–"

/** Where a timeline mark's centre sits in its row, so the rail can stop short of it. */
private val MarkCenterX = 8.dp
private val MarkCenterY = 18.dp

/**
 * Arena's home, set like the opening spread of a magazine: a dateline, a large serif greeting
 * and one paragraph that tells how things are, then a timeline of what the AIs did lately, the
 * machines as feature cards and the ways into everything else.
 */
@Composable
fun ArenaHome(model: HomeModel, actions: HomeActions) {
    val page = UniTheme.spacing.page
    Column(Modifier.fillMaxSize()) {
        HomeBar(model, actions)
        LazyColumn(
            Modifier.fillMaxWidth().weight(1f),
            contentPadding = PaddingValues(start = page, end = page, top = 14.dp, bottom = 40.dp),
        ) {
            item(key = "masthead") { Masthead(model) }
            if (model.machines.isEmpty()) {
                item(key = "empty") { EmptyHome(actions.onAdd, Modifier.padding(top = 28.dp)) }
            } else {
                item(key = "recent") { RecentActivity(model, actions, Modifier.padding(top = 32.dp)) }
                item(key = "machines") { MachinesTitle(model.total, Modifier.padding(top = 28.dp)) }
                items(model.machines, key = { "machine:${it.machine.id}" }) { entry ->
                    MachineFeature(entry, Modifier.padding(top = 12.dp)) { actions.onSelectMachine(entry.machine.id) }
                }
            }
            item(key = "shortcuts") { Shortcuts(actions, Modifier.padding(top = 28.dp)) }
            item(key = "colophon") {
                Text(
                    stringResource(R.string.security_note), Modifier.padding(top = 24.dp),
                    style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted,
                )
            }
        }
    }
}

/** The bar: the menu, the mark with its name and eyebrow, and refresh, diagnostics and add. */
@Composable
private fun HomeBar(model: HomeModel, actions: HomeActions) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().height(56.dp).padding(start = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = actions.onMenu) { Icon(Icons.Rounded.Menu, stringResource(R.string.drawer_open), tint = colors.text) }
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.padding(start = 2.dp).size(34.dp).clip(UniTheme.shapes.chip))
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Text(
                stringResource(R.string.app_name),
                style = MaterialTheme.typography.titleMedium.copy(fontSize = 18.sp, lineHeight = 21.sp, letterSpacing = (-0.2).sp),
                fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text(
                stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 15.sp),
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        // Only when there is something to tell: several failures in a row, not a reconnect blink.
        if (model.troubled) IconButton(onClick = actions.onDiagnostics) {
            Icon(Icons.Rounded.BugReport, stringResource(R.string.diagnostics_open), tint = colors.warning)
        }
        IconButton(onClick = actions.onRefresh, enabled = !model.refreshing) {
            if (model.refreshing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent)
            else Icon(Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), tint = colors.text)
        }
        IconButton(onClick = actions.onAdd) { Icon(Icons.Rounded.Add, stringResource(R.string.add_machine), tint = colors.text) }
    }
}

/** The dateline, the greeting set large and the paragraph that tells how things are. */
@Composable
private fun Masthead(model: HomeModel) {
    val colors = UniTheme.colors
    val type = UniTheme.type
    val date = todayText(model.nowEpochSeconds)
    Column(Modifier.fillMaxWidth()) {
        Text(
            if (type.labelUppercase) date.uppercase() else date,
            style = MaterialTheme.typography.labelLarge.copy(fontSize = 13.sp, lineHeight = 16.sp, letterSpacing = type.labelLetterSpacing),
            fontWeight = FontWeight.SemiBold, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            greetingText(model.greeting), Modifier.padding(top = 10.dp),
            style = MaterialTheme.typography.displaySmall.copy(fontSize = 40.sp, lineHeight = 44.sp, letterSpacing = (-1).sp),
            fontFamily = type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
        )
        if (model.machines.isNotEmpty()) Text(arenaHomeProse(model.total), Modifier.padding(top = 12.dp), style = arenaProseStyle())
    }
}

/**
 * What the AIs did lately, as a timeline. Whoever waits for the reader leads it whatever its age,
 * with its «Responder»; the latest changes follow in the order they happened.
 */
@Composable
private fun RecentActivity(model: HomeModel, actions: HomeActions, modifier: Modifier) {
    val colors = UniTheme.colors
    val waiting = model.activity.waiting
    val leading = waiting.take(WAITING_SHOWN)
    // A wait is told once, at the head; the digest's recent list may carry it too.
    val timeline = leading + model.activity.recent.filter { it.state != ActivityState.WAITING }
    val more = waiting.size - leading.size
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            ArenaSectionTitle(stringResource(R.string.design_recent_activity), Modifier.weight(1f))
            TextButton(onClick = actions.onNotices, shape = UniTheme.shapes.materialButton) {
                Text(
                    stringResource(R.string.arena_see_notices), style = MaterialTheme.typography.labelLarge.copy(fontSize = 14.sp),
                    fontWeight = FontWeight.Medium, color = colors.accent, maxLines = 1,
                )
            }
        }
        if (timeline.isEmpty()) Text(
            stringResource(R.string.arena_recent_empty), Modifier.padding(top = 4.dp),
            style = MaterialTheme.typography.bodyMedium, color = colors.muted,
        )
        Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
            timeline.forEachIndexed { index, item ->
                key(item.route) {
                    TimelineEntry(
                        item, model.nowEpochSeconds, first = index == 0, last = index == timeline.lastIndex && more == 0,
                        onOpen = { actions.onOpenWindow(item.route) },
                    )
                }
            }
            if (more > 0) Text(
                pluralStringResource(R.plurals.arena_more_waiting, more, more),
                Modifier.fillMaxWidth().clip(UniTheme.shapes.chip).clickable(onClick = actions.onNotices)
                    .heightIn(min = 44.dp).padding(start = MarkCenterX * 2 + 14.dp, top = 12.dp, bottom = 12.dp),
                style = MaterialTheme.typography.bodyMedium, color = colors.warning, fontWeight = FontWeight.Medium,
            )
        }
    }
}

/** One change on the timeline: a mark on the rail, who and what, and since when, where and which AI. */
@Composable
private fun TimelineEntry(item: ActivityItem, nowEpochSeconds: Long, first: Boolean, last: Boolean, onOpen: () -> Unit) {
    val colors = UniTheme.colors
    val rail = colors.muted.copy(alpha = .28f)
    val title = stringResource(
        when (item.state) {
            ActivityState.WAITING -> R.string.arena_recent_waiting
            ActivityState.WORKING -> R.string.arena_recent_working
            else -> R.string.arena_recent_idle
        },
    )
    val name = SpanStyle(fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, color = colors.text)
    val detail = listOfNotNull(
        elapsedText(item.sinceEpochSeconds, nowEpochSeconds), AgentLabel.of(item.agent), item.workspaceName, item.machineName,
    ).joinToString(" · ")
    Row(
        Modifier.fillMaxWidth()
            .drawBehind {
                // The rail runs from mark to mark and stops short of each, as if threaded through it.
                val x = MarkCenterX.toPx()
                val y = MarkCenterY.toPx()
                val gap = 11.dp.toPx()
                val width = 1.dp.toPx()
                if (!first) drawLine(rail, Offset(x, 0f), Offset(x, y - gap), width)
                if (!last) drawLine(rail, Offset(x, y + gap), Offset(x, size.height), width)
            }
            .clip(UniTheme.shapes.chip)
            .clickable(onClick = onOpen)
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.padding(top = 2.dp).size(MarkCenterX * 2), contentAlignment = Alignment.Center) { TimelineMark(item.state) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                styled(title, item.windowName to name),
                style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 20.sp),
                color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            if (detail.isNotEmpty()) Text(
                detail, style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
                color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
        if (item.state == ActivityState.WAITING) ArenaReplyButton(onOpen, Modifier.align(Alignment.CenterVertically))
    }
}

/** The mark on the rail: a ringed dot that asks, the turning arc that works, a quiet dot that rests. */
@Composable
private fun TimelineMark(state: ActivityState) {
    val colors = UniTheme.colors
    when (state) {
        ActivityState.WAITING -> Box(
            Modifier.size(16.dp).background(colors.warning.copy(alpha = .18f), CircleShape).padding(3.dp).background(colors.warning, CircleShape),
        )
        ActivityState.WORKING -> ActivityMark(ActivityState.WORKING, size = 14.dp, tone = colors.success)
        ActivityState.IDLE, ActivityState.UNKNOWN -> Box(Modifier.size(10.dp).background(colors.muted.copy(alpha = .5f), CircleShape))
    }
}

/** «Tus máquinas», with how many answer on the right. */
@Composable
private fun MachinesTitle(total: HomeSummary, modifier: Modifier) {
    val colors = UniTheme.colors
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        ArenaSectionTitle(stringResource(R.string.home_title), Modifier.weight(1f))
        ArenaDotLabel(
            stringResource(R.string.drawer_connected, total.connected, total.machines),
            if (total.connected > 0) colors.success else colors.muted,
        )
    }
}

/**
 * A machine as a feature card: its monogram, name in the serif, address and link, and under a
 * rule its windows, the AIs working and the ones waiting. What the AIs do is only told while the
 * machine answers; before that the last reading is a picture of the past.
 */
@Composable
private fun MachineFeature(entry: HomeMachine, modifier: Modifier, onClick: () -> Unit) {
    val colors = UniTheme.colors
    val machine = entry.machine
    val summary = entry.summary
    val live = entry.state == MachineState.CONNECTED
    val rule = colors.outline
    GlassCard(modifier.fillMaxWidth(), onClick = onClick) {
        Column(Modifier.fillMaxWidth().padding(start = 18.dp, top = 18.dp, end = 14.dp, bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ArenaMonogram(machine.name, 56.dp, UniTheme.shapes.chip, dimmed = !live)
                Column(Modifier.weight(1f).padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        machine.name,
                        style = MaterialTheme.typography.titleLarge.copy(fontSize = 20.sp, lineHeight = 24.sp, letterSpacing = (-0.2).sp),
                        fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        machine.endpoint.displayAddress, style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
                        fontFamily = UniTheme.type.identifierFamily, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    ArenaStatus(entry.state)
                }
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(22.dp), tint = colors.muted)
            }
            Row(
                Modifier.padding(top = 14.dp).fillMaxWidth()
                    .drawBehind { drawLine(rule, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }
                    .padding(top = 12.dp),
            ) {
                Figure(pluralStringResource(R.plurals.arena_stat_windows, summary.windows), summary.windows.toString(), null, Modifier.weight(1f))
                Figure(stringResource(R.string.arena_stat_working), if (live) summary.working.toString() else UNKNOWN_FIGURE, null, Modifier.weight(1f))
                val waiting = if (live) summary.waiting else 0
                Figure(
                    pluralStringResource(R.plurals.arena_stat_waiting, waiting), if (live) waiting.toString() else UNKNOWN_FIGURE,
                    colors.warning.takeIf { waiting > 0 }, Modifier.weight(1f),
                )
            }
        }
    }
}

/** A figure in the serif followed by what it counts: «27 ventanas». Nothing to count reads muted. */
@Composable
private fun Figure(template: String, number: String, tone: Color?, modifier: Modifier) {
    val colors = UniTheme.colors
    val quiet = number == "0" || number == UNKNOWN_FIGURE
    val figure = SpanStyle(
        fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, fontSize = 22.sp,
        color = tone ?: if (quiet) colors.muted else colors.text,
    )
    Text(
        styled(template, number to figure), modifier,
        style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 26.sp),
        color = tone ?: colors.muted, fontWeight = if (tone != null) FontWeight.Medium else FontWeight.Normal,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** The ways into everything that is not a machine, two by two and all the same height. */
@Composable
private fun Shortcuts(actions: HomeActions, modifier: Modifier) {
    val gap = 12.dp
    Column(modifier.fillMaxWidth()) {
        ArenaSectionTitle(stringResource(R.string.home_shortcuts))
        Column(Modifier.padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(gap)) {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
                ShortcutTile(Icons.Rounded.CloudUpload, R.string.upload_title, R.string.home_shortcut_files, Modifier.weight(1f).fillMaxHeight(), actions.onFiles)
                ShortcutTile(Icons.Rounded.History, R.string.history_title, R.string.home_shortcut_history, Modifier.weight(1f).fillMaxHeight(), actions.onHistory)
            }
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
                ShortcutTile(Icons.Rounded.NotificationsNone, R.string.notices_title, R.string.home_shortcut_notices, Modifier.weight(1f).fillMaxHeight(), actions.onNotices)
                ShortcutTile(Icons.Rounded.Tune, R.string.settings, R.string.home_shortcut_settings, Modifier.weight(1f).fillMaxHeight(), actions.onSettings)
            }
        }
    }
}

/** One way in: an icon on a sand tile, a name and one line of what it is. */
@Composable
private fun ShortcutTile(icon: ImageVector, title: Int, note: Int, modifier: Modifier, onClick: () -> Unit) {
    val colors = UniTheme.colors
    GlassCard(modifier, onClick = onClick) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(40.dp).background(colors.surfaceRaised, UniTheme.shapes.chip), contentAlignment = Alignment.Center) {
                Icon(icon, null, Modifier.size(22.dp), tint = colors.text)
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    stringResource(title), style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 20.sp),
                    fontWeight = FontWeight.SemiBold, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Text(
                    stringResource(note), style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
                    color = colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** No machine yet: what the app is for and the button that adds the first one. */
@Composable
private fun EmptyHome(onAdd: () -> Unit, modifier: Modifier) {
    val colors = UniTheme.colors
    GlassCard(modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().padding(24.dp)) {
            Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(64.dp).clip(UniTheme.shapes.card))
            Text(
                stringResource(R.string.empty_title), Modifier.padding(top = 18.dp),
                style = MaterialTheme.typography.headlineSmall.copy(fontSize = 26.sp, lineHeight = 31.sp, letterSpacing = (-0.4).sp),
                fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
            )
            Text(
                stringResource(R.string.empty_detail), Modifier.padding(top = 8.dp),
                style = arenaProseStyle().copy(fontSize = 16.sp, lineHeight = 24.sp),
            )
            Button(
                onClick = onAdd,
                modifier = Modifier.fillMaxWidth().padding(top = 22.dp).height(52.dp),
                shape = UniTheme.shapes.materialButton,
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            ) {
                Icon(Icons.Rounded.Add, null, Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
