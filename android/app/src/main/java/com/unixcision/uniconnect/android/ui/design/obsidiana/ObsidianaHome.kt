package com.unixcision.uniconnect.android.ui.design.obsidiana

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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.BugReport
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityItem
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AgentLabel
import com.unixcision.uniconnect.android.domain.NoticeRoute
import com.unixcision.uniconnect.android.domain.WindowFilter
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.design.HomeActions
import com.unixcision.uniconnect.android.ui.design.HomeMachine
import com.unixcision.uniconnect.android.ui.design.HomeModel
import com.unixcision.uniconnect.android.ui.design.greetingText
import com.unixcision.uniconnect.android.ui.design.todayText
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import java.text.Normalizer

/**
 * Obsidiana's home, a command centre: one strip with the state of the network and who waits,
 * then search and filters over a table of machines with a column per count, and the ways into
 * everything else as rows with their key.
 *
 * Counts of working and waiting AIs come only from machines that answer now: a machine that
 * stopped answering still holds its last list, and its spinners would be a picture of the past.
 */
@Composable
fun ObsidianaHome(model: HomeModel, actions: HomeActions) {
    val spacing = UniTheme.spacing
    var filter by rememberSaveable { mutableStateOf(WindowFilter.ALL) }
    var query by rememberSaveable { mutableStateOf("") }
    var allWaiting by rememberSaveable { mutableStateOf(false) }
    val live = remember(model.machines) { model.machines.filter { it.state == MachineState.CONNECTED } }
    val waiting = remember(model.activity, live) {
        val ids = live.mapTo(HashSet()) { it.machine.id }
        model.activity.waiting.filter { it.route.machineID in ids }
    }
    // With a single machine there is nothing to sift: search and filters would only push it down.
    val sifting = model.machines.size >= SIFT_FROM
    val needle = if (sifting) query.trim() else ""
    val inForce = if (sifting) filter else WindowFilter.ALL
    val shown = remember(model.machines, inForce, needle) {
        val folded = needle.folded()
        model.machines.filter { entry ->
            val answers = entry.state == MachineState.CONNECTED
            val inState = when (inForce) {
                WindowFilter.ALL -> true
                WindowFilter.WORKING -> answers && entry.summary.working > 0
                WindowFilter.WAITING -> answers && entry.summary.waiting > 0
            }
            inState && (folded.isEmpty() || entry.machine.name.folded().contains(folded) || entry.machine.endpoint.displayAddress.contains(folded))
        }
    }
    val quick = remember(actions) {
        listOf(
            QuickEntry(Icons.Rounded.Upload, R.string.upload_title, R.string.home_shortcut_files, Key.E, "E", actions.onFiles),
            QuickEntry(Icons.Rounded.History, R.string.history_title, R.string.home_shortcut_history, Key.H, "H", actions.onHistory),
            QuickEntry(Icons.Rounded.NotificationsNone, R.string.notices_title, R.string.home_shortcut_notices, Key.A, "A", actions.onNotices),
            QuickEntry(Icons.Rounded.Tune, R.string.settings, R.string.home_shortcut_settings, Key.Comma, ",", actions.onSettings),
        )
    }
    val visibleWaiting = if (allWaiting) waiting else waiting.take(WAITING_PREVIEW)

    ShortcutHost(remember(quick) { quick.associate { it.key to it.action } }, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            HomeBar(model.refreshing, model.troubled, actions)
            LazyColumn(
                Modifier.fillMaxWidth().weight(1f),
                contentPadding = PaddingValues(start = spacing.page, end = spacing.page, top = 4.dp, bottom = 32.dp),
            ) {
                item(key = "greeting", contentType = "greeting") {
                    Column(Modifier.fillMaxWidth().padding(start = 2.dp, top = 2.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            greetingText(model.greeting), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
                            letterSpacing = (-0.4).sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                        Text(todayText(model.nowEpochSeconds), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
                    }
                }
                if (model.machines.isNotEmpty()) {
                    item(key = "network", contentType = "network") {
                        NetworkStrip(
                            model = model, working = live.sumOf { it.summary.working }, waitingCount = live.sumOf { it.summary.waiting },
                            waiting = visibleWaiting, hidden = waiting.size - visibleWaiting.size,
                            folds = waiting.size > WAITING_PREVIEW, expanded = allWaiting,
                            onOpen = actions.onOpenWindow, onToggleAll = { allWaiting = !allWaiting },
                        )
                    }
                    if (sifting) {
                        item(key = "search", contentType = "search") {
                            SearchField(query, { query = it }, Modifier.padding(top = 12.dp))
                        }
                        item(key = "filters", contentType = "filters") {
                            SegmentedTabs(
                                options = WindowFilter.entries, selected = inForce, onSelect = { filter = it },
                                modifier = Modifier.padding(top = 10.dp),
                            ) { option, chosen -> FilterLabel(option, chosen) }
                        }
                    }
                }
                item(key = "machines-label", contentType = "label") { MachinesHeader(columns = model.machines.isNotEmpty()) }
                when {
                    model.machines.isEmpty() -> item(key = "empty", contentType = "empty") { EmptyPanel(actions.onAdd) }
                    shown.isEmpty() -> item(key = "no-match", contentType = "note") {
                        NoteRow(
                            if (needle.isNotEmpty()) stringResource(R.string.obsidiana_no_machines_match, needle)
                            else stringResource(R.string.obsidiana_no_machines_in_state),
                        )
                    }
                    else -> itemsIndexed(shown, key = { _, entry -> "machine:" + entry.machine.id }, contentType = { _, _ -> "machine" }) { index, entry ->
                        MachineRow(entry, Segment.of(index, shown.size)) { actions.onSelectMachine(entry.machine.id) }
                    }
                }
                item(key = "quick-label", contentType = "label") {
                    CapsLabel(stringResource(R.string.home_shortcuts), Modifier.padding(start = 15.dp, end = 15.dp, top = 22.dp, bottom = 8.dp))
                }
                itemsIndexed(quick, key = { _, entry -> entry.title }, contentType = { _, _ -> "quick" }) { index, entry ->
                    QuickRow(entry, Segment.of(index, quick.size))
                }
            }
        }
    }
}

/** From two machines on, the table can be searched and filtered. */
private const val SIFT_FROM = 2

/** How many windows waiting for the reader the strip lists before it folds the rest into a count. */
private const val WAITING_PREVIEW = 3

/** A way into something that is not a machine, with the key that reaches it from a keyboard. */
private class QuickEntry(val icon: ImageVector, val title: Int, val note: Int, val key: Key, val cap: String, val action: () -> Unit)

private val diacritics = Regex("\\p{Mn}+")

/** Lower case without accents, so «maquina» finds «Máquina». */
private fun String.folded(): String = Normalizer.normalize(this, Normalizer.Form.NFD).replace(diacritics, "").lowercase()

/** Menu, brand, and the three actions of the home: diagnostics when it has news, refresh and add. */
@Composable
private fun HomeBar(refreshing: Boolean, troubled: Boolean, actions: HomeActions) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = actions.onMenu) { Icon(Icons.Rounded.Menu, stringResource(R.string.drawer_open), tint = colors.text) }
        Row(Modifier.weight(1f).padding(start = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(30.dp))
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1)
                Text(stringResource(R.string.home_eyebrow), style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        // Only when there is something to tell: several failures in a row, not a reconnect blink.
        if (troubled) IconButton(onClick = actions.onDiagnostics) { Icon(Icons.Rounded.BugReport, stringResource(R.string.diagnostics_open), tint = colors.warning) }
        IconButton(onClick = actions.onRefresh, enabled = !refreshing) {
            if (refreshing) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.accent)
            else Icon(Icons.Rounded.Refresh, stringResource(R.string.refresh_connections), tint = colors.text)
        }
        IconButton(onClick = actions.onAdd) { Icon(Icons.Rounded.Add, stringResource(R.string.add_machine), tint = colors.text) }
    }
}

/**
 * The state of the network in one block: machines that answer, the three counts side by side and,
 * below, every window waiting for the reader with the way into it.
 */
@Composable
private fun NetworkStrip(
    model: HomeModel,
    working: Int,
    waitingCount: Int,
    waiting: List<ActivityItem>,
    hidden: Int,
    /** Whether there are more than the strip lists by default, so it can fold and unfold them. */
    folds: Boolean,
    expanded: Boolean,
    onOpen: (NoticeRoute) -> Unit,
    onToggleAll: () -> Unit,
) {
    val colors = UniTheme.colors
    val total = model.total
    Column(Modifier.fillMaxWidth().panel(rememberPanelShape(), colors.surface, colors.outline)) {
        Row(
            Modifier.fillMaxWidth().height(44.dp).padding(start = 14.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Dot(if (total.connected > 0) colors.success else colors.muted)
            Text(
                pluralStringResource(R.plurals.obsidiana_connected_of, total.machines, total.connected, total.machines),
                Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, fontWeight = FontWeight.Medium,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Tag(stringResource(R.string.obsidiana_network))
        }
        Hairline()
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            Metric(total.windows, pluralStringResource(R.plurals.obsidiana_metric_windows, total.windows), colors.text, Modifier.weight(1f).fillMaxHeight())
            VerticalHairline()
            Metric(working, pluralStringResource(R.plurals.obsidiana_metric_working, working), colors.text, Modifier.weight(1f).fillMaxHeight()) {
                if (working > 0) ActivityMark(ActivityState.WORKING, size = 14.dp)
            }
            VerticalHairline()
            Metric(waitingCount, pluralStringResource(R.plurals.obsidiana_metric_waiting, waitingCount), if (waitingCount > 0) colors.warning else colors.text, Modifier.weight(1f).fillMaxHeight()) {
                if (waitingCount > 0) Dot(colors.warning)
            }
        }
        waiting.forEach { item ->
            Hairline()
            WaitingRow(item) { onOpen(item.route) }
        }
        if (folds) {
            Hairline()
            Row(
                Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(onClick = onToggleAll).padding(horizontal = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (expanded) stringResource(R.string.obsidiana_show_less) else pluralStringResource(R.plurals.obsidiana_more_waiting, hidden, hidden),
                    Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = colors.muted,
                )
            }
        }
    }
}

/** One count of the strip: the number in mono, a mark beside it, and what it counts below. */
@Composable
private fun Metric(value: Int, label: String, tone: Color, modifier: Modifier, mark: @Composable () -> Unit = {}) {
    Column(modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                value.toString(), style = MaterialTheme.typography.titleLarge, fontFamily = ObsidianaMono, fontWeight = FontWeight.Medium,
                fontSize = 20.sp, lineHeight = 26.sp, letterSpacing = (-0.4).sp, color = tone, maxLines = 1,
            )
            mark()
        }
        Text(label, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** «APP 2 · te espera tu respuesta», where it lives and which AI asks; the whole row opens it. */
@Composable
private fun WaitingRow(item: ActivityItem, onOpen: () -> Unit) {
    val colors = UniTheme.colors
    val waits = stringResource(R.string.obsidiana_waits_for_you)
    val title = remember(item.windowName, waits, colors.warning) {
        buildAnnotatedString {
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(item.windowName) }
            withStyle(SpanStyle(color = colors.warning)) { append(" · "); append(waits) }
        }
    }
    val place = listOfNotNull(AgentLabel.of(item.agent), "${item.machineName} › ${item.workspaceName}").joinToString(" · ")
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(onClickLabel = stringResource(R.string.design_open), onClick = onOpen)
            .padding(start = 14.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Dot(colors.warning, size = 8.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(place, style = MaterialTheme.typography.bodySmall, fontFamily = ObsidianaMono, fontSize = 11.5.sp, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Row(Modifier.height(44.dp).padding(start = 8.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.design_open), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(16.dp), tint = colors.muted)
        }
    }
}

/** The search over the table: by name or address, accents ignored. */
@Composable
private fun SearchField(query: String, onQuery: (String) -> Unit, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    val shape = UniTheme.shapes.chip
    val focus = LocalFocusManager.current
    BasicTextField(
        value = query,
        onValueChange = onQuery,
        modifier = modifier.fillMaxWidth().height(44.dp).panel(shape, colors.surface, colors.outline),
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyMedium.copy(color = colors.text),
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
        decorationBox = { field ->
            Row(Modifier.fillMaxSize().padding(start = 12.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Rounded.Search, null, Modifier.size(17.dp), tint = colors.muted)
                Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                    if (query.isEmpty()) Text(
                        stringResource(R.string.obsidiana_search_machines), style = MaterialTheme.typography.bodyMedium, color = colors.muted,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                    field()
                }
                if (query.isNotEmpty()) IconButton(onClick = { onQuery("") }) {
                    Icon(Icons.Rounded.Close, stringResource(R.string.obsidiana_search_clear), Modifier.size(16.dp), tint = colors.muted)
                }
            }
        },
    )
}

/** «Todas», or a state with its dot in the colour it has everywhere else. */
@Composable
private fun FilterLabel(option: WindowFilter, chosen: Boolean) {
    val colors = UniTheme.colors
    when (option) {
        WindowFilter.ALL -> {}
        WindowFilter.WORKING -> Dot(colors.accent, size = 6.dp)
        WindowFilter.WAITING -> Dot(colors.warning, size = 6.dp)
    }
    Text(
        stringResource(
            when (option) {
                WindowFilter.ALL -> R.string.window_filter_all
                WindowFilter.WORKING -> R.string.window_filter_working
                WindowFilter.WAITING -> R.string.window_filter_waiting
            },
        ),
        style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        color = if (chosen) colors.text else colors.muted, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis,
    )
}

/** «MÁQUINAS» over the table, with the heads of its three count columns. */
@Composable
private fun MachinesHeader(columns: Boolean) {
    val muted = UniTheme.colors.muted
    Row(
        Modifier.fillMaxWidth().padding(start = 15.dp, end = 15.dp, top = 22.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        CapsLabel(stringResource(R.string.drawer_machines), Modifier.weight(1f))
        if (columns) {
            CapsLabel(stringResource(R.string.obsidiana_col_windows), Modifier.width(COLUMN), color = muted, textAlign = TextAlign.End)
            CapsLabel(stringResource(R.string.obsidiana_col_working), Modifier.width(COLUMN), color = muted, textAlign = TextAlign.End)
            CapsLabel(stringResource(R.string.obsidiana_col_waiting), Modifier.width(COLUMN), color = muted, textAlign = TextAlign.End)
        }
    }
}

/** Width of each count column of the machine table. */
private val COLUMN = 40.dp

/**
 * One machine as a table row: name, link state and address on the left, then windows, AIs working
 * and AIs waiting in their columns. A machine that does not answer shows a dash for the two
 * counts it cannot know.
 */
@Composable
private fun MachineRow(entry: HomeMachine, segment: Segment, onClick: () -> Unit) {
    val colors = UniTheme.colors
    val answers = entry.state == MachineState.CONNECTED
    val summary = entry.summary
    val (stateColor, stateText) = when (entry.state) {
        MachineState.CONNECTED -> colors.success to R.string.connected_machine
        MachineState.CHECKING -> colors.accent to R.string.checking_machine
        MachineState.SAVED -> colors.muted to R.string.saved_machine
    }
    Row(
        Modifier.fillMaxWidth().panelSegment(segment, rememberSegmentShape(segment), colors.surface, colors.outline)
            .clickable(onClick = onClick).heightIn(min = 80.dp).padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                entry.machine.name, style = MaterialTheme.typography.titleSmall, fontFamily = UniTheme.type.identifierFamily, fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold, letterSpacing = (-0.1).sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Dot(stateColor, size = 6.dp)
                Text(stringResource(stateText), style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(
                entry.machine.endpoint.displayAddress, style = MaterialTheme.typography.bodySmall, fontFamily = ObsidianaMono,
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        val windows = pluralStringResource(R.plurals.window_count, summary.windows, summary.windows)
        CountCell(summary.windows.toString(), if (answers) colors.text else colors.muted, windows)
        if (answers) {
            CountCell(summary.working.toString(), if (summary.working > 0) colors.text else colors.muted, pluralStringResource(R.plurals.obsidiana_working_count, summary.working, summary.working)) {
                if (summary.working > 0) ActivityMark(ActivityState.WORKING, size = 12.dp)
            }
            CountCell(summary.waiting.toString(), if (summary.waiting > 0) colors.warning else colors.muted, pluralStringResource(R.plurals.obsidiana_waiting_count, summary.waiting, summary.waiting)) {
                if (summary.waiting > 0) Dot(colors.warning, size = 6.dp)
            }
        } else {
            CountCell(UNKNOWN, colors.muted, null)
            CountCell(UNKNOWN, colors.muted, null)
        }
    }
}

/** What a count column shows when the machine cannot say. */
private const val UNKNOWN = "–"

/** One right-aligned count of the table, read aloud as a sentence instead of a bare number. */
@Composable
private fun CountCell(value: String, tone: Color, spoken: String?, mark: @Composable () -> Unit = {}) {
    Row(
        Modifier.width(COLUMN).clearAndSetSemantics { if (spoken != null) contentDescription = spoken },
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically,
    ) {
        mark()
        Text(
            value, style = MaterialTheme.typography.bodyMedium, fontFamily = ObsidianaMono, fontSize = 15.sp, fontWeight = FontWeight.Medium,
            color = tone, maxLines = 1, softWrap = false,
        )
    }
}

/** No machine saved yet: what UniConnect is for and the button that starts. */
@Composable
private fun EmptyPanel(onAdd: () -> Unit) {
    val colors = UniTheme.colors
    Column(
        Modifier.fillMaxWidth().panel(rememberPanelShape(), colors.surface, colors.outline).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Image(painterResource(R.drawable.uniconnect_mark), null, Modifier.size(44.dp))
        Text(stringResource(R.string.empty_title), Modifier.padding(top = 6.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(stringResource(R.string.empty_detail), style = MaterialTheme.typography.bodyMedium, color = colors.muted)
        Spacer(Modifier.height(6.dp))
        Button(
            onClick = onAdd, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = UniTheme.shapes.materialButton,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            Icon(Icons.Rounded.Add, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.add_machine), fontWeight = FontWeight.SemiBold)
        }
    }
}

/** A table with nothing to show under the current search or filter says so in its own row. */
@Composable
private fun NoteRow(text: String) {
    val colors = UniTheme.colors
    Box(
        Modifier.fillMaxWidth().panelSegment(Segment.ONLY, rememberSegmentShape(Segment.ONLY), colors.surface, colors.outline)
            .heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 12.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = MaterialTheme.typography.bodySmall, color = colors.muted)
    }
}

/** One quick access: its icon on a raised tile, the name with its note, and its key at the end. */
@Composable
private fun QuickRow(entry: QuickEntry, segment: Segment) {
    val colors = UniTheme.colors
    Row(
        Modifier.fillMaxWidth().panelSegment(segment, rememberSegmentShape(segment), colors.surface, colors.outline)
            .clickable(onClick = entry.action).heightIn(min = 48.dp).padding(start = 10.dp, end = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(28.dp).background(colors.surfaceRaised, UniTheme.shapes.chip), contentAlignment = Alignment.Center) {
            Icon(entry.icon, null, Modifier.size(16.dp), tint = colors.text)
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(entry.title), Modifier.alignByBaseline(), style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium, maxLines = 1,
            )
            Text(
                stringResource(entry.note), Modifier.alignByBaseline().weight(1f, fill = false), style = MaterialTheme.typography.bodySmall,
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        // The key is for a hardware keyboard; read aloud it would only interrupt the name.
        Tag(entry.cap, Modifier.clearAndSetSemantics {})
    }
}
