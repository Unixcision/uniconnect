package com.unixcision.uniconnect.android.ui.design.obsidiana

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.unixcision.uniconnect.android.R
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.WindowFilter
import com.unixcision.uniconnect.android.ui.KindBadge
import com.unixcision.uniconnect.android.ui.NotificationConnectionCard
import com.unixcision.uniconnect.android.ui.components.ActivityMark
import com.unixcision.uniconnect.android.ui.design.MachineActions
import com.unixcision.uniconnect.android.ui.design.MachineModel
import com.unixcision.uniconnect.android.ui.design.MachineOfflineCard
import com.unixcision.uniconnect.android.ui.design.MachineStaleBanner
import com.unixcision.uniconnect.android.ui.design.WindowItem
import com.unixcision.uniconnect.android.ui.design.WorkspaceSection
import com.unixcision.uniconnect.android.ui.design.activityText
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Obsidiana's machine screen: a breadcrumb, the machine as a title, the filter tabs with their
 * counts and then every workspace as a compact group of window rows. The tabs stay pinned on top
 * once scrolled past, because with seventy windows the filter is what gets used most.
 *
 * Activity is only drawn while the machine answers; without a connection the rows show names
 * and their AI, never a spinner left over from the last list.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ObsidianaMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    val spacing = UniTheme.spacing
    var filter by rememberSaveable { mutableStateOf(WindowFilter.ALL) }
    // Activity is only known while connected; filtering by it then would empty a list that is there.
    val active = if (model.connected) filter else WindowFilter.ALL
    var collapsed by rememberSaveable { mutableStateOf(emptySet<String>()) }
    val counts = remember(model.sections) { TabCounts.of(model.sections) }
    val lines = remember(model, active, collapsed) { Line.build(model, active, collapsed) }
    val list = rememberLazyListState()
    var tabsHeight by remember { mutableIntStateOf(0) }

    // A notice or a closed window names a workspace: bring its header to the top once, below the
    // pinned tabs, opening it and lifting a filter that hides it if needed.
    var pendingFocus by remember(model.focusWorkspaceID) { mutableStateOf(model.focusWorkspaceID) }
    LaunchedEffect(pendingFocus, lines) {
        val id = pendingFocus ?: return@LaunchedEffect
        if (model.sections.none { it.workspace.id == id }) { pendingFocus = null; return@LaunchedEffect }
        val index = lines.indexOfFirst { it is Line.Header && it.section.workspace.id == id }
        if (index < 0) {
            // Hidden by the filter: the lines rebuilt without it run this again.
            if (active == WindowFilter.ALL) pendingFocus = null else filter = WindowFilter.ALL
            return@LaunchedEffect
        }
        if (id in collapsed) collapsed = collapsed - id
        list.scrollToItem(index)
        if (index > lines.indexOf(Line.Tabs)) list.scrollBy(-tabsHeight.toFloat())
        pendingFocus = null
    }

    val shortcuts = if (model.canCreateWorkspace) mapOf(Key.N to actions.onCreateWorkspace) else emptyMap()
    ShortcutHost(shortcuts, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            MachineBar(model.machine.name, actions.onBack, menu)
            Box(Modifier.fillMaxWidth().weight(1f)) {
                LazyColumn(
                    Modifier.fillMaxSize(),
                    state = list,
                    contentPadding = PaddingValues(
                        start = spacing.page, end = spacing.page, top = 4.dp,
                        // Room for the floating button, so it never sits on the last row.
                        bottom = if (model.canCreateWorkspace) 96.dp else 32.dp,
                    ),
                ) {
                    lines.forEach { line ->
                        if (line == Line.Tabs) stickyHeader(key = line.key, contentType = "tabs") { _ ->
                            Box(Modifier.fillMaxWidth().background(UniTheme.colors.background).padding(vertical = 8.dp).onSizeChanged { tabsHeight = it.height }) {
                                WindowTabs(active, counts, model.connected) { filter = it }
                            }
                        } else item(key = line.key, contentType = line::class) {
                            LineContent(line, model, actions) { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id }
                        }
                    }
                }
                if (model.canCreateWorkspace) NewWorkspaceButton(actions.onCreateWorkspace, Modifier.align(Alignment.BottomEnd).padding(end = spacing.page, bottom = 18.dp))
            }
        }
    }
}

/** How many windows each tab would show, over every workspace. */
private data class TabCounts(val all: Int, val working: Int, val waiting: Int) {
    fun count(filter: WindowFilter): Int = when (filter) {
        WindowFilter.ALL -> all
        WindowFilter.WORKING -> working
        WindowFilter.WAITING -> waiting
    }

    companion object {
        fun of(sections: List<WorkspaceSection>): TabCounts {
            val windows = sections.flatMap { it.windows }
            return TabCounts(windows.size, windows.count { it.activity == ActivityState.WORKING }, windows.count { it.activity == ActivityState.WAITING })
        }
    }
}

/**
 * Every row of the screen in order, so the index of a workspace's header is known before it is
 * drawn and a notice can scroll straight to it.
 */
private sealed interface Line {
    val key: String

    data object Hero : Line { override val key get() = "hero" }
    data object Offline : Line { override val key get() = "offline" }
    data object Stale : Line { override val key get() = "stale" }
    data object Tabs : Line { override val key get() = "tabs" }
    data object LocalOnly : Line { override val key get() = "local-only" }
    data object NoWorkspaces : Line { override val key get() = "no-workspaces" }
    data object NoMatches : Line { override val key get() = "no-matches" }
    data object Notices : Line { override val key get() = "notices" }

    data class Header(val section: WorkspaceSection, val collapsed: Boolean, val first: Boolean) : Line {
        override val key get() = "workspace:" + section.workspace.id
    }

    data class Window(val workspaceID: String, val item: WindowItem, val segment: Segment) : Line {
        override val key get() = "window:$workspaceID/${item.window.id}"
    }

    data class EmptyWorkspace(val workspaceID: String) : Line {
        override val key get() = "empty:$workspaceID"
    }

    companion object {
        fun build(model: MachineModel, filter: WindowFilter, collapsed: Set<String>): List<Line> = buildList {
            add(Hero)
            if (!model.hasSnapshot) add(Offline)
            if (model.hasSnapshot && !model.connected) add(Stale)
            if (model.hasSnapshot) {
                if (model.sections.isNotEmpty()) add(Tabs)
                if (model.hostKeepsOrder == false) add(LocalOnly)
                if (model.sections.isEmpty()) add(NoWorkspaces)
                val sections = model.filtered(filter)
                if (model.sections.isNotEmpty() && sections.isEmpty()) add(NoMatches)
                sections.forEachIndexed { index, section ->
                    val id = section.workspace.id
                    val folded = id in collapsed
                    add(Header(section, folded, index == 0))
                    if (folded) return@forEachIndexed
                    if (section.windows.isEmpty()) add(EmptyWorkspace(id))
                    section.windows.forEachIndexed { at, item -> add(Window(id, item, Segment.of(at, section.windows.size))) }
                }
            }
            if (model.connected || model.noticeLink != null) add(Notices)
        }
    }
}

/** Draws one line of the list; the tabs are drawn by the list itself, pinned. */
@Composable
private fun LineContent(line: Line, model: MachineModel, actions: MachineActions, onToggle: (String) -> Unit) {
    val colors = UniTheme.colors
    when (line) {
        Line.Hero -> Hero(model)
        Line.Offline -> MachineOfflineCard(model, actions.onConnect)
        Line.Stale -> MachineStaleBanner(model, actions.onConnect, Modifier.padding(bottom = 4.dp))
        Line.LocalOnly -> Text(
            stringResource(R.string.box_local_only), Modifier.padding(start = 2.dp, top = 2.dp, bottom = 6.dp),
            style = MaterialTheme.typography.bodySmall, color = colors.warning,
        )
        Line.NoWorkspaces -> Note(stringResource(R.string.no_workspaces), Modifier.padding(top = 8.dp))
        Line.NoMatches -> Note(stringResource(R.string.design_no_filtered_windows), Modifier.padding(top = 8.dp))
        Line.Notices -> Box(Modifier.padding(top = 24.dp)) {
            NotificationConnectionCard(model.noticeLink, model.connected, actions.onEnableNotices, actions.onDisableNotices)
        }
        is Line.Header -> WorkspaceHeader(
            line.section, line.collapsed, line.first,
            onToggle = { onToggle(line.section.workspace.id) },
            onHold = { actions.onHoldWorkspace(line.section.workspace.id) },
            onCreateWindow = { actions.onCreateWindow(line.section.workspace.id) },
        )
        is Line.Window -> WindowRow(
            line.item, line.segment,
            onOpen = { actions.onOpenWindow(line.workspaceID, line.item.window.id) },
            onHold = { actions.onHoldWindow(line.workspaceID, line.item.window.id) },
        )
        is Line.EmptyWorkspace -> Note(stringResource(R.string.no_windows))
        Line.Tabs -> {}
    }
}

/** Back, the breadcrumb «Máquinas / nombre» and the machine's own menu. */
@Composable
private fun MachineBar(name: String, onBack: () -> Unit, menu: @Composable () -> Unit) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, stringResource(R.string.back), tint = colors.text) }
        Row(Modifier.weight(1f).padding(start = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(
                Modifier.heightIn(min = 44.dp).clip(UniTheme.shapes.chip).clickable(role = Role.Button, onClick = onBack).padding(horizontal = 4.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(R.string.design_back_machines), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, color = colors.muted, maxLines = 1)
            }
            Text("/", style = MaterialTheme.typography.bodyMedium, fontFamily = ObsidianaMono, fontSize = 13.sp, color = colors.muted)
            Text(
                name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp,
                fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        menu()
    }
}

/** The machine as a title: its tile, its name, how it answers with its window count, and its address. */
@Composable
private fun Hero(model: MachineModel) {
    val colors = UniTheme.colors
    val (tone, state) = when {
        model.connected -> colors.success to R.string.connected_machine
        model.checking -> colors.accent to R.string.checking_machine
        else -> colors.muted to R.string.saved_machine
    }
    val stateText = stringResource(state)
    val windows = if (model.hasSnapshot) pluralStringResource(R.plurals.window_count, model.summary.windows, model.summary.windows) else null
    val line = remember(stateText, windows, colors) {
        buildAnnotatedString {
            withStyle(SpanStyle(color = colors.text)) { append(stateText) }
            if (windows != null) withStyle(SpanStyle(color = colors.muted)) { append(" · "); append(windows) }
        }
    }
    Row(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Box(Modifier.size(52.dp).panel(rememberPanelShape(), colors.surface, colors.outline), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Computer, null, Modifier.size(24.dp), tint = colors.text)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                model.machine.name, style = MaterialTheme.typography.titleLarge, fontFamily = UniTheme.type.identifierFamily,
                fontWeight = FontWeight.SemiBold, letterSpacing = (-0.4).sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Dot(tone)
                Text(line, style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(model.machine.endpoint.displayAddress, style = MaterialTheme.typography.bodySmall, fontFamily = ObsidianaMono, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/**
 * «Todas 67 · Trabajando 7 · Te esperan 1». Without a connection the two states cannot be known:
 * their tabs stay in place, faded and without a count.
 */
@Composable
private fun WindowTabs(selected: WindowFilter, counts: TabCounts, connected: Boolean, onSelect: (WindowFilter) -> Unit) {
    val colors = UniTheme.colors
    SegmentedTabs(
        options = WindowFilter.entries, selected = selected, onSelect = onSelect,
        enabled = { connected || it == WindowFilter.ALL },
    ) { option, chosen ->
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
            Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp, fontWeight = FontWeight.Medium,
            color = if (chosen) colors.text else colors.muted, maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis,
        )
        if (connected || option == WindowFilter.ALL) Text(
            counts.count(option).toString(), style = MaterialTheme.typography.bodySmall, fontFamily = ObsidianaMono,
            color = colors.muted, maxLines = 1, softWrap = false,
        )
    }
}

/**
 * A workspace's header: its name and window count in mono, its favourite star, what its AIs are
 * doing and «+» for a new window. A tap folds it, a long press opens its sheet.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceHeader(section: WorkspaceSection, collapsed: Boolean, first: Boolean, onToggle: () -> Unit, onHold: () -> Unit, onCreateWindow: () -> Unit) {
    val colors = UniTheme.colors
    val workspace = section.workspace
    // The windows listed under it, so a filter and its count never disagree.
    val count = section.windows.size
    val spokenCount = pluralStringResource(R.plurals.window_count, count, count)
    Row(
        Modifier.fillMaxWidth().padding(top = if (first) 4.dp else 8.dp).heightIn(min = 44.dp).clip(UniTheme.shapes.chip)
            .combinedClickable(
                onClickLabel = stringResource(if (collapsed) R.string.obsidiana_expand else R.string.obsidiana_collapse),
                onLongClickLabel = stringResource(R.string.obsidiana_workspace_options),
                onLongClick = onHold,
                onClick = onToggle,
            )
            .padding(start = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Rounded.KeyboardArrowDown, null, Modifier.size(16.dp).rotate(if (collapsed) -90f else 0f), tint = colors.muted)
        Text(
            workspace.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodySmall, fontFamily = ObsidianaMono,
            fontWeight = FontWeight.Medium, letterSpacing = 0.25.sp, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            count.toString(), Modifier.clearAndSetSemantics { contentDescription = spokenCount }, style = MaterialTheme.typography.bodySmall,
            fontFamily = ObsidianaMono, color = colors.muted, maxLines = 1,
        )
        if (section.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(13.dp), tint = colors.warning)
        section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING }?.let { ActivityMark(it, size = 14.dp) }
        // Only the remote kind is worth a badge here; «LOCAL» on every group would be noise.
        if (workspace.isSSH == true) KindBadge(workspace)
        Spacer(Modifier.weight(1f))
        if (section.canCreateWindow) IconButton(onClick = onCreateWindow) {
            Icon(Icons.Rounded.Add, stringResource(R.string.obsidiana_new_window_in, workspace.name), Modifier.size(18.dp), tint = colors.muted)
        }
    }
}

/**
 * One window: its mark, its name and state, and its AI as a tag. A window waiting for the reader
 * says so in the warning colour and offers «Responder»; the whole row opens it.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(item: WindowItem, segment: Segment, onOpen: () -> Unit, onHold: () -> Unit) {
    val colors = UniTheme.colors
    val waiting = item.activity == ActivityState.WAITING
    val line = if (waiting) listOfNotNull(item.agent, stringResource(R.string.obsidiana_waiting_line)).joinToString(" · ") else activityText(item.activity)
    Row(
        Modifier.fillMaxWidth().panelSegment(segment, rememberSegmentShape(segment), colors.surface, colors.outline)
            .combinedClickable(onLongClickLabel = stringResource(R.string.obsidiana_window_options), onLongClick = onHold, onClick = onOpen)
            .heightIn(min = 52.dp).padding(start = 14.dp, end = 12.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) {
            item.activity?.let { state ->
                when (state) {
                    ActivityState.WORKING, ActivityState.WAITING -> ActivityMark(state, size = 14.dp)
                    ActivityState.IDLE -> IdleRing()
                    ActivityState.UNKNOWN -> {}
                }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    item.window.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyMedium,
                    fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(12.dp), tint = colors.warning)
            }
            line?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = if (waiting) colors.warning else colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        when {
            // Part of the row, which already opens the window: a second target would only be smaller.
            waiting -> Text(
                stringResource(R.string.design_reply),
                Modifier.background(colors.warning.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 10.dp, vertical = 6.dp),
                style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.warning, maxLines = 1,
            )
            item.agent != null -> Tag(item.agent)
        }
    }
}

/** A quiet line in its own panel: an empty workspace, no workspaces, nothing under the filter. */
@Composable
private fun Note(text: String, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    Box(
        modifier.fillMaxWidth().panelSegment(Segment.ONLY, rememberSegmentShape(Segment.ONLY), colors.surface, colors.outline)
            .heightIn(min = 48.dp).padding(horizontal = 14.dp, vertical = 10.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = MaterialTheme.typography.bodySmall, color = colors.muted)
    }
}

/** The one floating action of the screen, in the accent, with its key for a hardware keyboard. */
@Composable
private fun NewWorkspaceButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    val shape = UniTheme.shapes.button
    Row(
        modifier.height(48.dp).shadow(8.dp, shape).clip(shape).background(colors.accent)
            .clickable(role = Role.Button, onClick = onClick).padding(start = 14.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Rounded.Add, null, Modifier.size(18.dp), tint = colors.onAccent)
        Text(stringResource(R.string.obsidiana_new_workspace), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, color = colors.onAccent, maxLines = 1)
        Tag("N", Modifier.clearAndSetSemantics {}, fill = colors.onAccent.copy(alpha = .14f), content = colors.onAccent, edge = null)
    }
}
