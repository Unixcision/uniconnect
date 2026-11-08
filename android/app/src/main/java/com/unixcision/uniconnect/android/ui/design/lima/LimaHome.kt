package com.unixcision.uniconnect.android.ui.design.lima

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
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.WebAsset
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityItem
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AgentLabel
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.design.HomeActions
import com.unixcision.uniconnect.android.ui.design.HomeMachine
import com.unixcision.uniconnect.android.ui.design.HomeModel
import com.unixcision.uniconnect.android.ui.design.greetingText
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Lima's home, a bento panel. One wide lime block counts the AIs at work and splits them by
 * machine; beside the reply that waits for the reader sit two small numbers; then the machines as
 * tiles and four small ways into everything else. Every row of the grid is as tall as its tallest
 * tile, so the panel keeps its edges whatever the names are.
 */
@Composable
fun LimaHome(model: HomeModel, actions: HomeActions) {
    val page = UniTheme.spacing.page
    Column(Modifier.fillMaxSize()) {
        LimaHomeBar(model, actions)
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = page, end = page, top = 4.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(LimaGutter),
        ) {
            item(key = "greeting") { LimaGreeting(model) }
            if (model.machines.isEmpty()) {
                item(key = "empty") { LimaEmptyBlock(actions.onAdd) }
            } else {
                item(key = "working") { LimaWorkingBlock(model) }
                item(key = "glance") {
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(LimaGutter)) {
                        LimaWaitingBlock(model.activity.waiting, actions.onOpenWindow, Modifier.weight(1f).fillMaxHeight())
                        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(LimaGutter)) {
                            LimaStatTile(
                                label = stringResource(R.string.home_stat_connected), icon = Icons.Rounded.Wifi,
                                value = model.total.connected.toString(),
                                unit = pluralStringResource(R.plurals.lima_of_machines, model.total.machines, model.total.machines),
                                modifier = Modifier.fillMaxWidth().weight(1f),
                            )
                            LimaStatTile(
                                label = stringResource(R.string.windows), icon = Icons.Rounded.WebAsset,
                                value = model.total.windows.toString(), unit = stringResource(R.string.lima_windows_total),
                                modifier = Modifier.fillMaxWidth().weight(1f),
                            )
                        }
                    }
                }
                // Two tiles a row; an odd one out takes the whole row instead of leaving a hole.
                items(model.machines.chunked(2), key = { row -> "machines:" + row.joinToString("|") { it.machine.id } }) { row ->
                    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(LimaGutter)) {
                        row.forEach { item ->
                            LimaMachineTile(item, { actions.onSelectMachine(item.machine.id) }, Modifier.weight(1f).fillMaxHeight())
                        }
                    }
                }
            }
            item(key = "shortcuts") { LimaShortcuts(actions) }
        }
    }
}

/** The bar: menu, the brand, and square buttons for diagnostics, refresh and a new machine. */
@Composable
private fun LimaHomeBar(model: HomeModel, actions: HomeActions) {
    val colors = UniTheme.colors
    Row(
        Modifier.fillMaxWidth().padding(horizontal = UniTheme.spacing.page, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LimaSquareButton(Icons.Rounded.Menu, stringResource(R.string.drawer_open), actions.onMenu)
        Row(Modifier.weight(1f).padding(start = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(36.dp))
            Column(Modifier.padding(start = 10.dp)) {
                Text(
                    stringResource(R.string.app_name), style = MaterialTheme.typography.titleMedium, fontSize = 17.sp,
                    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                Text(stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        // Only when there is something to tell: several failures in a row, not a reconnect blink.
        if (model.troubled) LimaSquareButton(Icons.Rounded.BugReport, stringResource(R.string.diagnostics_open), actions.onDiagnostics, tint = colors.warning)
        LimaSquareButton(
            Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), actions.onRefresh, enabled = !model.refreshing,
            content = if (model.refreshing) ({ CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = colors.accent) }) else null,
        )
        LimaSquareButton(Icons.Rounded.Add, stringResource(R.string.add_machine), actions.onAdd, fill = colors.accent, tint = colors.onAccent)
    }
}

@Composable
private fun LimaGreeting(model: HomeModel) {
    Column(Modifier.fillMaxWidth().padding(start = 2.dp, top = 14.dp, bottom = 8.dp)) {
        Text(
            greetingText(model.greeting), style = MaterialTheme.typography.headlineLarge,
            fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, letterSpacing = (-0.025).em,
        )
        Text(
            stringResource(if (model.machines.isEmpty()) R.string.home_subtitle else R.string.lima_home_subtitle),
            Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted,
        )
    }
}

/**
 * The lime block: how many AIs are working, as large as the screen allows, and a bar per machine
 * for its share. Only the busiest machines get a bar, so the block keeps its size with many.
 */
@Composable
private fun LimaWorkingBlock(model: HomeModel) {
    val colors = UniTheme.colors
    val ink = colors.onAccent
    val working = model.total.working
    val busiest = remember(model.machines) { model.machines.sortedByDescending { it.summary.working }.take(BREAKDOWN_LIMIT) }
    val digits = working.toString().length
    val numberSize = when { digits <= 2 -> 104.sp; digits == 3 -> 76.sp; else -> 56.sp }
    Column(Modifier.fillMaxWidth().clip(UniTheme.shapes.card).background(colors.accent).padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 20.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            LimaEyebrow(stringResource(R.string.home_stat_working), Modifier.weight(1f), color = ink)
            if (working > 0) ActivityMark(ActivityState.WORKING, size = 20.dp, tone = ink)
        }
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Text(
                working.toString(), color = ink, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold,
                fontSize = numberSize, lineHeight = numberSize * .9f, letterSpacing = (-0.05).em, maxLines = 1,
            )
            Column(Modifier.weight(1f).padding(bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                busiest.forEach { item -> LimaShareBar(item, working) }
            }
        }
    }
}

/** One machine's share of the working AIs, as a flat bar that starts square and ends round. */
@Composable
private fun LimaShareBar(item: HomeMachine, total: Int) {
    val ink = UniTheme.colors.onAccent
    val bar = ContinuousRoundedShape(topStart = 0.dp, topEnd = 4.dp, bottomEnd = 4.dp, bottomStart = 0.dp)
    val share = if (total > 0) (item.summary.working.toFloat() / total).coerceIn(0f, 1f) else 0f
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                item.machine.name, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, fontFamily = UniTheme.type.identifierFamily,
                fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Text(
                item.summary.working.toString(), Modifier.padding(start = 8.dp), style = MaterialTheme.typography.titleSmall,
                fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold, color = ink,
            )
        }
        Box(Modifier.padding(top = 6.dp).fillMaxWidth().height(10.dp).background(ink.copy(alpha = .14f), bar)) {
            if (share > 0f) Box(Modifier.fillMaxWidth(share).fillMaxHeight().background(ink, bar))
        }
    }
}

/**
 * Who waits for the reader: the most recent window, where it lives and its AI, and «Responder»
 * to open it. With nobody waiting it stays in place and says so, so the grid keeps its shape.
 */
@Composable
private fun LimaWaitingBlock(waiting: List<ActivityItem>, onOpen: (NoticeRoute) -> Unit, modifier: Modifier) {
    val colors = UniTheme.colors
    val first = waiting.firstOrNull()
    val tone = if (first != null) colors.warning else colors.muted
    val identifier = UniTheme.type.identifierFamily
    Column(modifier.clip(UniTheme.shapes.card).background(colors.surfaceRaised).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).background(tone, CircleShape))
            LimaEyebrow(
                stringResource(if (waiting.size > 1) R.string.home_stat_waiting else R.string.activity_state_waiting),
                Modifier.weight(1f).padding(start = 8.dp), color = tone,
            )
            Text(waiting.size.toString(), fontFamily = identifier, fontWeight = FontWeight.Bold, fontSize = 20.sp, color = tone, maxLines = 1)
        }
        Spacer(Modifier.weight(1f).heightIn(min = 10.dp))
        if (first == null) {
            Text(stringResource(R.string.lima_waiting_none), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
        } else {
            AgentLabel.of(first.agent)?.let { agent ->
                Text(
                    agent, Modifier.padding(bottom = 6.dp).background(colors.text.copy(alpha = .08f), UniTheme.shapes.chip).padding(horizontal = 8.dp, vertical = 3.dp),
                    style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                first.windowName, style = MaterialTheme.typography.titleLarge, fontSize = 19.sp, lineHeight = 23.sp, fontFamily = identifier,
                fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Text(first.workspaceName, Modifier.padding(top = 2.dp), style = MaterialTheme.typography.bodySmall, fontFamily = identifier, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(first.machineName, style = MaterialTheme.typography.bodySmall, fontFamily = identifier, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(
                Modifier.padding(top = 12.dp).fillMaxWidth().heightIn(min = 44.dp).clip(UniTheme.shapes.button).background(colors.warning)
                    .clickable(role = Role.Button) { onOpen(first.route) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Text(
                    stringResource(R.string.design_reply), style = MaterialTheme.typography.titleSmall, fontSize = 15.sp,
                    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.onAccent,
                )
                Icon(Icons.AutoMirrored.Rounded.ArrowForward, null, Modifier.padding(start = 8.dp).size(18.dp), tint = colors.onAccent)
            }
        }
    }
}

/** A small number with what it counts: «2 de 2 máquinas», «94 en total». */
@Composable
private fun LimaStatTile(label: String, icon: ImageVector, value: String, unit: String, modifier: Modifier) {
    val colors = UniTheme.colors
    Column(modifier.heightIn(min = 82.dp).clip(UniTheme.shapes.card).background(colors.surface).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            LimaEyebrow(label, Modifier.weight(1f))
            Icon(icon, null, Modifier.size(16.dp), tint = colors.muted)
        }
        Spacer(Modifier.weight(1f).heightIn(min = 8.dp))
        Row {
            Text(
                value, Modifier.alignByBaseline(), fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold,
                fontSize = 30.sp, lineHeight = 32.sp, letterSpacing = (-0.03).em, maxLines = 1,
            )
            Text(
                unit, Modifier.alignByBaseline().padding(start = 6.dp), style = MaterialTheme.typography.bodySmall, fontSize = 13.sp,
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * A saved machine as a tile: its mark, what its AIs are doing (only while it answers: a list read
 * before connecting is a picture of the past), name, address, state and its windows, big.
 */
@Composable
private fun LimaMachineTile(item: HomeMachine, onClick: () -> Unit, modifier: Modifier) {
    val colors = UniTheme.colors
    val identifier = UniTheme.type.identifierFamily
    val live = item.state == MachineState.CONNECTED
    Column(modifier.clip(UniTheme.shapes.card).background(colors.surface).clickable(role = Role.Button, onClick = onClick).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            LimaMachineGlyph(36.dp, fill = colors.surfaceRaised, tint = if (live) colors.text else colors.muted)
            Spacer(Modifier.weight(1f))
            if (live && item.summary.waiting > 0) LimaCountChip(ActivityState.WAITING, item.summary.waiting, colors.warning)
            if (live && item.summary.working > 0) LimaCountChip(ActivityState.WORKING, item.summary.working, colors.accent)
        }
        Text(
            item.machine.name, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.titleMedium, fontFamily = identifier,
            fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
        Text(
            item.machine.endpoint.displayAddress, Modifier.padding(top = 4.dp), style = MaterialTheme.typography.labelSmall,
            fontFamily = identifier, letterSpacing = 0.sp, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        LimaStateChip(item.state, fill = colors.surfaceRaised, modifier = Modifier.padding(top = 10.dp))
        Spacer(Modifier.weight(1f).heightIn(min = 12.dp))
        Row {
            Text(
                item.summary.windows.toString(), Modifier.alignByBaseline(), fontFamily = identifier, fontWeight = FontWeight.Bold,
                fontSize = 28.sp, lineHeight = 30.sp, letterSpacing = (-0.03).em, maxLines = 1,
            )
            Text(
                pluralStringResource(R.plurals.lima_windows_word, item.summary.windows), Modifier.alignByBaseline().padding(start = 6.dp),
                style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Four small tiles into what is not a machine: files, history, notices and settings. */
@Composable
private fun LimaShortcuts(actions: HomeActions) {
    val entries = listOf(
        Triple(Icons.Rounded.CloudUpload, R.string.upload_title, actions.onFiles),
        Triple(Icons.Rounded.History, R.string.history_title, actions.onHistory),
        Triple(Icons.Rounded.NotificationsActive, R.string.notices_title, actions.onNotices),
        Triple(Icons.Rounded.Tune, R.string.settings, actions.onSettings),
    )
    Column(verticalArrangement = Arrangement.spacedBy(LimaGutter)) {
        entries.chunked(2).forEach { row ->
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(LimaGutter)) {
                row.forEach { (icon, title, onClick) -> LimaShortcut(icon, stringResource(title), onClick, Modifier.weight(1f).fillMaxHeight()) }
            }
        }
    }
}

@Composable
private fun LimaShortcut(icon: ImageVector, title: String, onClick: () -> Unit, modifier: Modifier) {
    Row(
        modifier.heightIn(min = 56.dp).clip(UniTheme.shapes.card).background(UniTheme.colors.surface)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, Modifier.size(20.dp), tint = UniTheme.colors.accent)
        Text(title, style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** No machine yet: what the app is for and the one button that starts it. */
@Composable
private fun LimaEmptyBlock(onAdd: () -> Unit) {
    val colors = UniTheme.colors
    Column(
        Modifier.fillMaxWidth().clip(UniTheme.shapes.card).background(colors.surface).padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(56.dp))
        Text(
            stringResource(R.string.empty_title), Modifier.padding(top = 4.dp), style = MaterialTheme.typography.titleLarge,
            fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
        )
        Text(stringResource(R.string.empty_detail), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
        Button(
            onClick = onAdd,
            modifier = Modifier.padding(top = 8.dp).fillMaxWidth().heightIn(min = 52.dp),
            shape = UniTheme.shapes.materialButton,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            Icon(Icons.Rounded.Add, null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
        }
    }
}

/** How many machines get a bar in the lime block; the rest still count in its number. */
private const val BREAKDOWN_LIMIT = 4
