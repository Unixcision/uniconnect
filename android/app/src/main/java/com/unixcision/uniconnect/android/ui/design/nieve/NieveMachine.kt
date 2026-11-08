package com.unixcision.uniconnect.android.ui.design.nieve

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.WindowFilter
import com.unixcision.uniconnect.android.ui.MachineState
import com.unixcision.uniconnect.android.ui.NotificationConnectionCard
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.design.MachineActions
import com.unixcision.uniconnect.android.ui.design.MachineModel
import com.unixcision.uniconnect.android.ui.design.MachineOfflineCard
import com.unixcision.uniconnect.android.ui.design.MachineStaleBanner
import com.unixcision.uniconnect.android.ui.design.WindowItem
import com.unixcision.uniconnect.android.ui.design.WorkspaceSection
import com.unixcision.uniconnect.android.ui.design.activityText
import com.unixcision.uniconnect.android.ui.design.windowLine
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Nieve's machine, a page of Apple's Settings: «Inicio» back, the machine's name as the large
 * title over its state, one block with its numbers, and every workspace at once as a group of
 * its own under a small header, its windows as rows. «Nuevo espacio de trabajo» waits in a bar at
 * the bottom, where the thumb is.
 *
 * Every row is a lazy item of its own, so a machine with seventy windows only composes what is on
 * screen, and the list can be told exactly where a workspace's header sits.
 */
@Composable
fun NieveMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    var chosen by rememberSaveable(model.machine.id) { mutableStateOf(WindowFilter.ALL) }
    // Without a connection no window has a known state, so any filter but «Todas» would empty the list.
    val filter = if (model.connected) chosen else WindowFilter.ALL
    val lines = remember(model, filter) { machineLines(model, filter) }
    val list = rememberLazyListState()
    // The workspace to bring into view, kept until its header exists: the list may still be on its way.
    var pendingFocus by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(model.focusWorkspaceID) {
        val id = model.focusWorkspaceID ?: return@LaunchedEffect
        // A filter that hides the workspace a notice named would leave nothing to show.
        if (model.filtered(filter).none { it.workspace.id == id }) chosen = WindowFilter.ALL
        pendingFocus = id
    }
    LaunchedEffect(pendingFocus, lines) {
        val id = pendingFocus ?: return@LaunchedEffect
        val index = lines.indexOfFirst { it is MachineLine.Header && it.section.workspace.id == id }
        if (index >= 0) {
            list.scrollToItem(index)
            pendingFocus = null
        }
    }
    val page = UniTheme.spacing.page
    Column(Modifier.fillMaxSize()) {
        MachineBar(model, actions, menu)
        LazyColumn(Modifier.fillMaxWidth().weight(1f), state = list, contentPadding = PaddingValues(bottom = 32.dp)) {
            items(lines, key = { it.key }, contentType = { it::class }) { line ->
                when (line) {
                    MachineLine.Title -> MachineTitle(model)
                    MachineLine.Offline -> MachineOfflineCard(model, actions.onConnect, Modifier.padding(start = page, end = page, top = 20.dp))
                    MachineLine.Stale -> MachineStaleBanner(model, actions.onConnect, Modifier.padding(start = page, end = page, top = 16.dp))
                    MachineLine.Summary -> Summary(model)
                    MachineLine.Filter -> FilterControl(filter) { chosen = it }
                    MachineLine.LocalOnly -> NieveFooter(stringResource(R.string.box_local_only), Modifier.padding(top = 12.dp), color = UniTheme.colors.warning)
                    is MachineLine.Message -> MessageRow(line.text)
                    is MachineLine.Header -> WorkspaceHeader(
                        line.section,
                        onHold = { actions.onHoldWorkspace(line.section.workspace.id) },
                        onCreate = if (line.section.canCreateWindow) ({ actions.onCreateWindow(line.section.workspace.id) }) else null,
                    )
                    is MachineLine.Window -> WindowRow(
                        line.item, line.slot,
                        onOpen = { actions.onOpenWindow(line.workspaceID, line.item.window.id) },
                        onHold = { actions.onHoldWindow(line.workspaceID, line.item.window.id) },
                    )
                    is MachineLine.NoWindows -> NieveRow(Modifier.nieveGroup(), minHeight = 52.dp) {
                        Text(stringResource(R.string.no_windows), style = NieveText.body, color = UniTheme.colors.muted)
                    }
                    MachineLine.Notices -> Column(Modifier.fillMaxWidth()) {
                        NieveHeader(stringResource(R.string.drawer_notices))
                        Box(Modifier.padding(horizontal = page)) {
                            NotificationConnectionCard(model.noticeLink, model.connected, actions.onEnableNotices, actions.onDisableNotices)
                        }
                    }
                }
            }
        }
        if (model.canCreateWorkspace) CreateBar(actions.onCreateWorkspace)
    }
}

/** One item of the machine's list; the key is what the lazy list and the focus look for. */
private sealed interface MachineLine {
    val key: String

    data object Title : MachineLine { override val key: String get() = "title" }
    data object Offline : MachineLine { override val key: String get() = "offline" }
    data object Stale : MachineLine { override val key: String get() = "stale" }
    data object Summary : MachineLine { override val key: String get() = "summary" }
    data object Filter : MachineLine { override val key: String get() = "filter" }
    data object LocalOnly : MachineLine { override val key: String get() = "local-only" }
    data object Notices : MachineLine { override val key: String get() = "notices" }
    data class Message(val text: Int) : MachineLine { override val key: String get() = "message" }
    data class Header(val section: WorkspaceSection) : MachineLine { override val key: String get() = "h:${section.workspace.id}" }
    data class Window(val workspaceID: String, val item: WindowItem, val slot: NieveSlot) : MachineLine {
        override val key: String get() = "w:$workspaceID/${item.window.id}"
    }
    data class NoWindows(val workspaceID: String) : MachineLine { override val key: String get() = "e:$workspaceID" }
}

/** The machine's list, top to bottom, for [filter]. */
private fun machineLines(model: MachineModel, filter: WindowFilter): List<MachineLine> = buildList {
    add(MachineLine.Title)
    if (!model.hasSnapshot) {
        add(MachineLine.Offline)
        if (model.connected || model.noticeLink != null) add(MachineLine.Notices)
        return@buildList
    }
    if (!model.connected) add(MachineLine.Stale)
    add(MachineLine.Summary)
    if (model.connected && model.sections.isNotEmpty()) add(MachineLine.Filter)
    if (model.hostKeepsOrder == false) add(MachineLine.LocalOnly)
    val sections = model.filtered(filter)
    when {
        model.sections.isEmpty() -> add(MachineLine.Message(R.string.no_workspaces))
        sections.isEmpty() -> add(MachineLine.Message(R.string.design_no_filtered_windows))
    }
    sections.forEach { section ->
        val id = section.workspace.id
        add(MachineLine.Header(section))
        if (section.windows.isEmpty()) add(MachineLine.NoWindows(id))
        else section.windows.forEachIndexed { index, item -> add(MachineLine.Window(id, item, NieveSlot.of(index, section.windows.size))) }
    }
    if (model.connected || model.noticeLink != null) add(MachineLine.Notices)
}

/** «Inicio» back on the left; checking the link and the machine's menu on the right. */
@Composable
private fun MachineBar(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 4.dp).height(52.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.clip(UniTheme.shapes.button).clickable(role = Role.Button, onClick = actions.onBack).heightIn(min = 44.dp).padding(end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, stringResource(R.string.back), Modifier.size(32.dp), tint = colors.accent)
            Text(stringResource(R.string.design_back_home), style = NieveText.back, color = colors.accent, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = actions.onConnect, enabled = !model.checking) {
            if (model.checking) CircularProgressIndicator(Modifier.size(20.dp), color = colors.accent, strokeWidth = 2.dp)
            else Icon(Icons.Rounded.Refresh, stringResource(R.string.check_connection), tint = colors.accent)
        }
        menu()
    }
}

/** The machine's name as the large title, and under it how it answers and where it is. */
@Composable
private fun MachineTitle(model: MachineModel) {
    val state = when {
        model.connected -> MachineState.CONNECTED
        model.checking -> MachineState.CHECKING
        else -> MachineState.SAVED
    }
    Column(Modifier.fillMaxWidth().padding(start = UniTheme.spacing.page, end = UniTheme.spacing.page, top = 4.dp)) {
        Text(
            model.machine.name, style = NieveText.largeTitle, fontFamily = UniTheme.type.identifierFamily,
            maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
        NieveStateLine(state, model.machine.endpoint.displayAddress, NieveText.body, Modifier.padding(top = 6.dp), dot = 8.dp)
    }
}

/**
 * Windows, AIs working and AIs waiting. Working and waiting are only known while the machine
 * answers; until then the block counts what the last list had, workspaces and windows.
 */
@Composable
private fun Summary(model: MachineModel) {
    val summary = model.summary
    val stats = if (model.connected) listOf(
        NieveStat(NieveStatKind.WINDOWS, summary.windows, stringResource(R.string.nieve_stat_windows)),
        NieveStat(NieveStatKind.WORKING, summary.working, pluralStringResource(R.plurals.nieve_stat_working, summary.working)),
        NieveStat(NieveStatKind.WAITING, summary.waiting, pluralStringResource(R.plurals.nieve_stat_waiting, summary.waiting)),
    ) else listOf(
        NieveStat(NieveStatKind.WORKSPACES, model.sections.size, stringResource(R.string.design_workspaces)),
        NieveStat(NieveStatKind.WINDOWS, summary.windows, stringResource(R.string.nieve_stat_windows)),
    )
    Column(Modifier.fillMaxWidth().padding(top = 16.dp).nieveGroup()) { NieveStatRow(stats) }
}

/**
 * Todas, Trabajando, Te esperan: Apple's segmented control. With seventy windows, the two or
 * three that wait are what the reader came for.
 */
@Composable
private fun FilterControl(selected: WindowFilter, onSelect: (WindowFilter) -> Unit) {
    val colors = UniTheme.colors
    val on = if (colors.isDark) colors.text.copy(alpha = .16f) else colors.surface
    Row(
        Modifier.fillMaxWidth().padding(start = UniTheme.spacing.page, end = UniTheme.spacing.page, top = 20.dp)
            .height(44.dp).background(colors.text.copy(alpha = .07f), UniTheme.shapes.button).padding(3.dp),
    ) {
        WindowFilter.entries.forEach { option ->
            val chosen = option == selected
            Box(
                Modifier.weight(1f).fillMaxHeight().clip(UniTheme.shapes.chip)
                    .then(if (chosen) Modifier.background(on).border(0.5.dp, colors.outline, UniTheme.shapes.chip) else Modifier)
                    .selectable(selected = chosen, role = Role.Tab, onClick = { onSelect(option) }),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    stringResource(
                        when (option) {
                            WindowFilter.ALL -> R.string.window_filter_all
                            WindowFilter.WORKING -> R.string.window_filter_working
                            WindowFilter.WAITING -> R.string.window_filter_waiting
                        },
                    ),
                    Modifier.padding(horizontal = 6.dp), style = NieveText.detail.copy(fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (chosen) colors.text else colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** A note that stands for an empty list: no workspaces, or none in the chosen state. */
@Composable
private fun MessageRow(text: Int) {
    NieveRow(Modifier.padding(top = 20.dp).nieveGroup(), minHeight = 52.dp) {
        Text(stringResource(text), style = NieveText.body, color = UniTheme.colors.muted)
    }
}

/**
 * A workspace's header, like a section of Settings: its name, a star when it is a favourite and
 * the mark of its most pressing window, then how many windows and the «+» that adds one. A tap
 * or a long press opens its sheet (favourite, order, relaunch).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceHeader(section: WorkspaceSection, onHold: () -> Unit, onCreate: (() -> Unit)?) {
    val colors = UniTheme.colors
    val page = UniTheme.spacing.page
    val workspace = section.workspace
    val count = pluralStringResource(R.plurals.window_count, section.windows.size, section.windows.size)
    Row(
        Modifier.fillMaxWidth().padding(start = page + 4.dp, end = page, top = 18.dp)
            .clip(UniTheme.shapes.chip)
            .combinedClickable(onLongClick = onHold, onClick = onHold)
            .heightIn(min = 44.dp)
            .padding(start = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (section.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
            Text(
                if (UniTheme.type.labelUppercase) workspace.name.uppercase() else workspace.name, Modifier.weight(1f, fill = false),
                style = NieveText.header.copy(fontWeight = FontWeight.SemiBold), fontFamily = UniTheme.type.identifierFamily,
                color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING }?.let { ActivityMark(it, size = 14.dp) }
        }
        Text(
            if (workspace.isSSH == true) "${stringResource(R.string.ssh_workspace)} · $count" else count,
            Modifier.padding(start = 10.dp), style = NieveText.detail, color = colors.muted, maxLines = 1,
        )
        if (onCreate != null) IconButton(onClick = onCreate, Modifier.size(44.dp)) {
            Icon(Icons.Rounded.Add, stringResource(R.string.new_window), Modifier.size(22.dp), tint = colors.accent)
        } else Spacer(Modifier.width(16.dp))
    }
}

/**
 * One window: what its AI is doing in the square, the name, «Claude · Trabajando» under it.
 * A waiting window carries «Responder» instead of the chevron; the whole row opens it either way.
 */
@Composable
private fun WindowRow(item: WindowItem, slot: NieveSlot, onOpen: () -> Unit, onHold: () -> Unit) {
    val colors = UniTheme.colors
    val waiting = item.activity == ActivityState.WAITING
    val reply = stringResource(R.string.design_reply)
    NieveRow(
        Modifier.nieveGroup(slot), rule = if (slot.roundsTop) null else 64.dp,
        onClickLabel = if (waiting) reply else null, onLongClick = onHold, onClick = onOpen,
    ) {
        WindowSquare(item.activity)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    item.window.name, Modifier.weight(1f, fill = false), style = NieveText.title,
                    fontFamily = UniTheme.type.identifierFamily, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
            }
            windowLine(item)?.let { line ->
                Text(toned(line, item.activity), Modifier.padding(top = 2.dp), style = NieveText.detail, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (waiting) NieveReply(reply) else NieveChevron()
    }
}

/**
 * The square at the start of a window row. A spinner while its AI works, the raised hand when it
 * waits, a moon when it rests; a plain terminal when nothing is known, which is every window of
 * a machine that does not answer: an old list must not look busy.
 */
@Composable
private fun WindowSquare(activity: ActivityState?) {
    val colors = UniTheme.colors
    when (activity) {
        ActivityState.WORKING -> NieveTile(36.dp, colors.accentSoft) { ActivityMark(ActivityState.WORKING, size = 18.dp) }
        ActivityState.WAITING -> NieveTile(36.dp, colors.warning.copy(alpha = .14f)) { ActivityMark(ActivityState.WAITING, size = 20.dp) }
        ActivityState.IDLE -> NieveTile(36.dp, colors.surfaceRaised) { Icon(Icons.Rounded.DarkMode, null, Modifier.size(19.dp), tint = colors.muted) }
        ActivityState.UNKNOWN, null -> NieveTile(36.dp, colors.surfaceRaised) { Icon(Icons.Rounded.Terminal, null, Modifier.size(19.dp), tint = colors.muted) }
    }
}

/** [line] with its state word in the state's colour: the accent while working, the warning while waiting. */
@Composable
private fun toned(line: String, state: ActivityState?): AnnotatedString {
    val word = activityText(state)
    val tone = when (state) {
        ActivityState.WORKING -> UniTheme.colors.accent
        ActivityState.WAITING -> UniTheme.colors.warning
        else -> null
    }
    return remember(line, word, tone) {
        if (word == null || tone == null || !line.endsWith(word)) AnnotatedString(line)
        else buildAnnotatedString {
            append(line.dropLast(word.length))
            withStyle(SpanStyle(color = tone, fontWeight = if (state == ActivityState.WAITING) FontWeight.SemiBold else FontWeight.Medium)) { append(word) }
        }
    }
}

/** «Nuevo espacio de trabajo», on a bar under the list with a hairline above it. */
@Composable
private fun CreateBar(onCreate: () -> Unit) {
    val colors = UniTheme.colors
    val rule = nieveRuleColor()
    Box(
        Modifier.fillMaxWidth().background(colors.background)
            .drawBehind {
                val stroke = maxOf(1f, 0.5.dp.toPx())
                drawLine(rule, Offset(0f, stroke / 2f), Offset(size.width, stroke / 2f), stroke)
            }
            .padding(horizontal = UniTheme.spacing.page, vertical = 10.dp),
    ) {
        Button(
            onClick = onCreate, modifier = Modifier.fillMaxWidth().height(50.dp), shape = UniTheme.shapes.materialButton,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) {
            Icon(Icons.Rounded.Add, null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.new_workspace), style = NieveText.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
