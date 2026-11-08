package com.unixcision.uniconnect.android.ui.design.nieve

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityItem
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AgentLabel
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.design.HomeActions
import com.unixcision.uniconnect.android.ui.design.HomeMachine
import com.unixcision.uniconnect.android.ui.design.HomeModel
import com.unixcision.uniconnect.android.ui.design.greetingText
import com.unixcision.uniconnect.android.ui.design.todayText
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** How many waiting windows the summary lists before the rest become a footnote. */
private const val WAITING_SHOWN = 3

/**
 * Nieve's home, shaped like Apple's Settings: a bar with the brand, the date over a large
 * greeting, one white block with the three numbers that matter and whoever waits for the reader,
 * the machines as an inset grouped list and the ways into everything else as four quiet tiles.
 *
 * The bar stays put while the rest scrolls, so the menu and «Añadir máquina» are always in reach.
 */
@Composable
fun NieveHome(model: HomeModel, actions: HomeActions) {
    Column(Modifier.fillMaxSize()) {
        HomeBar(model, actions)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = 40.dp)) {
            item(key = "greeting", contentType = "greeting") { GreetingBlock(model) }
            if (model.machines.isEmpty()) {
                item(key = "empty", contentType = "empty") { EmptyBlock(actions.onAdd) }
            } else {
                item(key = "summary", contentType = "summary") { SummaryBlock(model, actions) }
                item(key = "machines", contentType = "header") { NieveHeader(stringResource(R.string.drawer_machines)) }
                itemsIndexed(model.machines, key = { _, entry -> "m:${entry.machine.id}" }, contentType = { _, _ -> "machine" }) { index, entry ->
                    MachineRow(entry, NieveSlot.of(index, model.machines.size)) { actions.onSelectMachine(entry.machine.id) }
                }
            }
            item(key = "shortcuts", contentType = "header") { NieveHeader(stringResource(R.string.home_shortcuts)) }
            item(key = "tiles", contentType = "tiles") { Shortcuts(actions) }
            item(key = "security", contentType = "footer") { NieveFooter(stringResource(R.string.security_note), Modifier.padding(top = 10.dp)) }
        }
    }
}

/** Menu, brand and the bar's actions, all in the accent the way Apple tints its bar buttons. */
@Composable
private fun HomeBar(model: HomeModel, actions: HomeActions) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 6.dp, top = 4.dp).height(52.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = actions.onMenu) { Icon(Icons.Rounded.Menu, stringResource(R.string.drawer_open), tint = colors.accent) }
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.padding(start = 2.dp).size(30.dp))
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Text(stringResource(R.string.app_name), style = NieveText.barTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(stringResource(R.string.home_eyebrow), style = NieveText.barNote, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        // Only when there is something to tell: several failures in a row, not a reconnect blink.
        if (model.troubled) IconButton(onClick = actions.onDiagnostics) {
            Icon(Icons.Rounded.BugReport, stringResource(R.string.diagnostics_open), tint = colors.warning)
        }
        IconButton(onClick = actions.onRefresh, enabled = !model.refreshing) {
            if (model.refreshing) CircularProgressIndicator(Modifier.size(20.dp), color = colors.accent, strokeWidth = 2.dp)
            else Icon(Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), tint = colors.accent)
        }
        IconButton(onClick = actions.onAdd) { Icon(Icons.Rounded.Add, stringResource(R.string.add_machine), Modifier.size(26.dp), tint = colors.accent) }
    }
}

/** The date, the greeting that leads the page and how many machines answer. */
@Composable
private fun GreetingBlock(model: HomeModel) {
    val colors = UniTheme.colors
    val total = model.total
    val today = todayText(model.nowEpochSeconds)
    Column(Modifier.fillMaxWidth().padding(start = UniTheme.spacing.page, end = UniTheme.spacing.page, top = 6.dp)) {
        Text(if (UniTheme.type.labelUppercase) today.uppercase() else today, style = NieveText.eyebrow, color = colors.muted, maxLines = 1)
        Text(greetingText(model.greeting), Modifier.padding(top = 2.dp), style = NieveText.largeTitle, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (model.machines.isEmpty()) {
                Text(stringResource(R.string.home_subtitle), style = NieveText.body, color = colors.muted)
            } else {
                NieveDot(if (total.connected > 0) colors.success else colors.muted)
                Text(
                    pluralStringResource(R.plurals.nieve_machines_connected, total.machines, total.connected, total.machines),
                    style = NieveText.body, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Windows, AIs working and AIs waiting over every machine, and under them, in the same block,
 * the windows that wait for the reader with a way to answer each.
 */
@Composable
private fun SummaryBlock(model: HomeModel, actions: HomeActions) {
    val total = model.total
    val waiting = model.activity.waiting
    val shown = waiting.take(WAITING_SHOWN)
    Column(Modifier.fillMaxWidth().padding(top = 16.dp)) {
        Column(Modifier.nieveGroup()) {
            NieveStatRow(
                listOf(
                    NieveStat(NieveStatKind.WINDOWS, total.windows, stringResource(R.string.nieve_stat_windows)),
                    NieveStat(NieveStatKind.WORKING, total.working, pluralStringResource(R.plurals.nieve_stat_working, total.working)),
                    NieveStat(NieveStatKind.WAITING, total.waiting, pluralStringResource(R.plurals.nieve_stat_waiting, total.waiting)),
                ),
            )
            shown.forEachIndexed { index, item ->
                // The first rule closes the numbers, inset on both sides; the rest follow the text.
                WaitingRow(item, rule = if (index == 0) 16.dp else 64.dp, ruleEnd = if (index == 0) 16.dp else 0.dp) { actions.onOpenWindow(item.route) }
            }
        }
        val rest = waiting.size - shown.size
        if (rest > 0) NieveFooter(pluralStringResource(R.plurals.nieve_waiting_more, rest, rest))
    }
}

/** «Claude te espera en APP 2», where it is, and «Responder», which opens the window. */
@Composable
private fun WaitingRow(item: ActivityItem, rule: Dp, ruleEnd: Dp, onReply: () -> Unit) {
    val colors = UniTheme.colors
    val agent = AgentLabel.of(item.agent)
    val reply = stringResource(R.string.design_reply)
    NieveRow(rule = rule, ruleEnd = ruleEnd, onClickLabel = reply, onClick = onReply) {
        NieveTile(36.dp, colors.warning.copy(alpha = .14f)) { ActivityMark(ActivityState.WAITING, size = 20.dp) }
        Column(Modifier.weight(1f)) {
            Text(
                if (agent != null) stringResource(R.string.nieve_waiting_title, agent, item.windowName)
                else stringResource(R.string.nieve_waiting_window, item.windowName),
                style = NieveText.title, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${item.workspaceName} · ${item.machineName}", Modifier.padding(top = 1.dp),
                style = NieveText.detail, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        NieveReply(reply)
    }
}

/** One saved machine as a row of the group: who it is, whether it answers and what its AIs do. */
@Composable
private fun MachineRow(entry: HomeMachine, slot: NieveSlot, onSelect: () -> Unit) {
    val colors = UniTheme.colors
    val live = entry.state == MachineState.CONNECTED
    NieveRow(
        Modifier.nieveGroup(slot), rule = if (slot.roundsTop) null else 68.dp,
        padding = PaddingValues(start = 16.dp, end = 14.dp, top = 12.dp, bottom = 12.dp), onClick = onSelect,
    ) {
        NieveTile(40.dp, if (live) colors.accentSoft else colors.surfaceRaised) {
            Icon(Icons.Rounded.Computer, null, Modifier.size(22.dp), tint = if (live) colors.accent else colors.muted)
        }
        Column(Modifier.weight(1f)) {
            Text(entry.machine.name, style = NieveText.headline, fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis)
            NieveStateLine(entry.state, entry.machine.endpoint.displayAddress, NieveText.detail, Modifier.padding(top = 2.dp))
            countsLine(entry)?.let { counts ->
                Text(counts, Modifier.padding(top = 3.dp), style = NieveText.detail, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        NieveChevron()
    }
}

/**
 * «67 ventanas · 7 trabajando · 1 te espera», with the waiting in the warning colour. A machine
 * that does not answer only gives its window count: what its AIs did last time is not news.
 */
@Composable
private fun countsLine(entry: HomeMachine): AnnotatedString? {
    val summary = entry.summary
    val windows = pluralStringResource(R.plurals.window_count, summary.windows, summary.windows)
    if (entry.state != MachineState.CONNECTED) return if (summary.windows > 0) AnnotatedString(windows) else null
    val working = pluralStringResource(R.plurals.nieve_working_count, summary.working, summary.working)
    val waiting = pluralStringResource(R.plurals.nieve_waiting_count, summary.waiting, summary.waiting)
    val warning = UniTheme.colors.warning
    return buildAnnotatedString {
        append(windows)
        append(" · ")
        append(working)
        append(" · ")
        if (summary.waiting > 0) withStyle(SpanStyle(color = warning, fontWeight = FontWeight.SemiBold)) { append(waiting) } else append(waiting)
    }
}

/** No machine yet: what the app is for and the one button that starts it. */
@Composable
private fun EmptyBlock(onAdd: () -> Unit) {
    val colors = UniTheme.colors
    Column(
        Modifier.fillMaxWidth().padding(top = 20.dp).nieveGroup().padding(horizontal = 20.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(72.dp))
        Text(
            stringResource(R.string.empty_title), Modifier.padding(top = 16.dp), style = NieveText.headline.copy(fontSize = 20.sp, lineHeight = 25.sp),
            textAlign = TextAlign.Center,
        )
        Text(stringResource(R.string.empty_detail), Modifier.padding(top = 6.dp), style = NieveText.body, color = colors.muted, textAlign = TextAlign.Center)
        Button(
            onClick = onAdd, modifier = Modifier.fillMaxWidth().padding(top = 20.dp).height(50.dp), shape = UniTheme.shapes.materialButton,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            Icon(Icons.Rounded.Add, null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.add_machine), style = NieveText.title)
        }
    }
}

/** The four ways into what is not a machine, two by two and of one height. */
@Composable
private fun Shortcuts(actions: HomeActions) {
    val gap = UniTheme.spacing.gapSmall
    Column(Modifier.fillMaxWidth().padding(horizontal = UniTheme.spacing.page), verticalArrangement = Arrangement.spacedBy(gap)) {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
            ShortcutTile(Icons.Rounded.Upload, stringResource(R.string.upload_title), stringResource(R.string.home_shortcut_files), Modifier.weight(1f).fillMaxHeight(), actions.onFiles)
            ShortcutTile(Icons.Rounded.History, stringResource(R.string.history_title), stringResource(R.string.home_shortcut_history), Modifier.weight(1f).fillMaxHeight(), actions.onHistory)
        }
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
            ShortcutTile(Icons.Rounded.Notifications, stringResource(R.string.notices_title), stringResource(R.string.home_shortcut_notices), Modifier.weight(1f).fillMaxHeight(), actions.onNotices)
            ShortcutTile(Icons.Rounded.Tune, stringResource(R.string.settings), stringResource(R.string.home_shortcut_settings), Modifier.weight(1f).fillMaxHeight(), actions.onSettings)
        }
    }
}

/** An icon in an indigo square, a name and one line of what it is. */
@Composable
private fun ShortcutTile(icon: ImageVector, title: String, note: String, modifier: Modifier, onClick: () -> Unit) {
    val colors = UniTheme.colors
    Column(modifier.clip(UniTheme.shapes.card).background(colors.surface).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 13.dp)) {
        NieveTile(32.dp, colors.accentSoft) { Icon(icon, null, Modifier.size(18.dp), tint = colors.accent) }
        Text(title, Modifier.padding(top = 11.dp), style = NieveText.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(note, Modifier.padding(top = 2.dp), style = NieveText.detail, color = colors.muted, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}
