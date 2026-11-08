package com.unixcision.uniconnect.android.ui.design.obsidiana

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.animateScrollBy
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Computer
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.layout.layout
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
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
import com.unixcision.uniconnect.android.ui.design.RecentWindow
import com.unixcision.uniconnect.android.ui.design.WindowItem
import com.unixcision.uniconnect.android.ui.design.WorkspaceSection
import com.unixcision.uniconnect.android.ui.design.WorkspaceTabSelection
import com.unixcision.uniconnect.android.ui.design.WorkspaceTabs
import com.unixcision.uniconnect.android.ui.design.activityText
import com.unixcision.uniconnect.android.ui.design.elapsedText
import com.unixcision.uniconnect.android.ui.design.rememberWorkspaceTab
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/**
 * Obsidiana's machine screen: a breadcrumb, the machine as a title, the workspaces as an editor's
 * tabs with the filter under them, and then the chosen workspace's windows (or every workspace
 * as a compact group of rows under «Todos», or every window by its last prompt under
 * «Recientes»). Both strips stay pinned on top once scrolled past, because with seventy windows
 * they are what gets used most.
 *
 * Activity is only drawn while the machine answers; without a connection the rows show names
 * and their AI, never a spinner left over from the last list.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ObsidianaMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    val spacing = UniTheme.spacing
    val selection = rememberWorkspaceTab(model)
    var filter by rememberSaveable { mutableStateOf(WindowFilter.ALL) }
    // Activity is only known while connected; filtering by it then would empty a list that is there.
    val active = if (model.connected) filter else WindowFilter.ALL
    var collapsed by rememberSaveable { mutableStateOf(emptySet<String>()) }
    val counts = remember(model, selection.selected) {
        // «Recientes» lists windows, not workspaces: its counts come from the same flat list.
        if (selection.showsRecent) TabCounts.of(model.recentWindows().map { it.item })
        else TabCounts.of(model.visible(selection.selected, WindowFilter.ALL).flatMap { it.windows })
    }
    val lines = remember(model, selection.selected, active, collapsed) { Line.build(model, selection.selected, active, collapsed) }
    val list = rememberLazyListState()

    // A notice or a closed window names a workspace and the tab goes there by itself; a filter
    // that would leave that tab empty is lifted.
    LaunchedEffect(model.focusWorkspaceID) {
        val id = model.focusWorkspaceID ?: return@LaunchedEffect
        if (model.sections.any { it.workspace.id == id } && model.visible(id, active).isEmpty()) filter = WindowFilter.ALL
    }
    // Another tab starts at its top, right under the pinned strips. The first run is skipped so a
    // rotation keeps the place the list was restored to.
    var shownTab by rememberSaveable { mutableStateOf(selection.selected) }
    LaunchedEffect(selection.selected) {
        if (selection.selected == shownTab) return@LaunchedEffect
        shownTab = selection.selected
        val tabs = lines.indexOf(Line.Tabs)
        if (tabs >= 0 && list.firstVisibleItemIndex >= tabs) list.scrollToItem(tabs)
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
                            // Edge to edge, so the workspace strip scrolls out under the screen's sides like an editor's.
                            Column(Modifier.bleed(spacing.page).background(UniTheme.colors.background)) {
                                WorkspaceTabRow(model, selection, actions.onHoldWorkspace)
                                Box(Modifier.padding(horizontal = spacing.page, vertical = 8.dp)) {
                                    WindowTabs(active, counts, model.connected) { filter = it }
                                }
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

/**
 * Lets a block inside the padded list reach both edges of the screen, [inset] past each side.
 * The list only clips top and bottom, so what lies over its side padding is still drawn.
 */
private fun Modifier.bleed(inset: Dp): Modifier = layout { measurable, constraints ->
    if (!constraints.hasBoundedWidth) {
        val placeable = measurable.measure(constraints)
        return@layout layout(placeable.width, placeable.height) { placeable.place(0, 0) }
    }
    val side = inset.roundToPx()
    val width = constraints.maxWidth + side * 2
    val placeable = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
    layout(constraints.maxWidth, placeable.height) { placeable.place(-side, 0) }
}

/** How many windows each filter would show, over the chosen tab. */
private data class TabCounts(val all: Int, val working: Int, val waiting: Int) {
    fun count(filter: WindowFilter): Int = when (filter) {
        WindowFilter.ALL -> all
        WindowFilter.WORKING -> working
        WindowFilter.WAITING -> waiting
    }

    companion object {
        fun of(windows: List<WindowItem>): TabCounts =
            TabCounts(windows.size, windows.count { it.activity == ActivityState.WORKING }, windows.count { it.activity == ActivityState.WAITING })
    }
}

/**
 * Every row of the screen in order, so the index of the pinned strips is known before they are
 * drawn and another tab can scroll straight back to them.
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

    /** The bar above a single workspace's windows, which stands in for its header. */
    data class Bar(val section: WorkspaceSection) : Line {
        override val key get() = "bar:" + section.workspace.id
    }

    data class Window(val workspaceID: String, val item: WindowItem, val segment: Segment) : Line {
        override val key get() = "window:$workspaceID/${item.window.id}"
    }

    data class EmptyWorkspace(val workspaceID: String) : Line {
        override val key get() = "empty:$workspaceID"
    }

    /** A window under «Recientes», with the workspace it belongs to. */
    data class Recent(val recent: RecentWindow, val segment: Segment) : Line {
        override val key get() = "recent:${recent.workspace.id}/${recent.item.window.id}"
    }

    companion object {
        fun build(model: MachineModel, tab: String, filter: WindowFilter, collapsed: Set<String>): List<Line> = buildList {
            add(Hero)
            if (!model.hasSnapshot) add(Offline)
            if (model.hasSnapshot && !model.connected) add(Stale)
            if (model.hasSnapshot) {
                if (model.sections.isNotEmpty()) add(Tabs)
                if (model.hostKeepsOrder == false) add(LocalOnly)
                if (model.sections.isEmpty()) add(NoWorkspaces)
                val sections = model.visible(tab, filter)
                // One workspace: its bar stays even when the filter empties it, so «+» and the star do too.
                val single = model.sections.takeIf { tab != WorkspaceTabs.ALL }?.firstOrNull { it.workspace.id == tab }
                if (tab == WorkspaceTabs.RECENT) {
                    // One panel of windows from every workspace, newest prompt first; no headers, no «+».
                    val recent = model.recentWindows(filter)
                    if (recent.isEmpty()) add(NoMatches)
                    recent.forEachIndexed { at, window -> add(Recent(window, Segment.of(at, recent.size))) }
                } else if (single != null) {
                    val id = single.workspace.id
                    val windows = sections.firstOrNull()?.windows.orEmpty()
                    add(Bar(single))
                    when {
                        single.windows.isEmpty() -> add(EmptyWorkspace(id))
                        windows.isEmpty() -> add(NoMatches)
                        else -> windows.forEachIndexed { at, item -> add(Window(id, item, Segment.of(at, windows.size))) }
                    }
                } else {
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
        is Line.Bar -> WorkspaceBar(
            line.section,
            onHold = { actions.onHoldWorkspace(line.section.workspace.id) },
            onTogglePin = { actions.onToggleWorkspacePin(line.section.workspace.id) },
            onCreateWindow = { actions.onCreateWindow(line.section.workspace.id) },
        )
        is Line.Window -> WindowRow(
            line.item, line.segment,
            onOpen = { actions.onOpenWindow(line.workspaceID, line.item.window.id) },
            onHold = { actions.onHoldWindow(line.workspaceID, line.item.window.id) },
        )
        is Line.EmptyWorkspace -> Note(stringResource(R.string.no_windows))
        is Line.Recent -> RecentRow(
            line.recent, line.segment, model.nowEpochSeconds,
            onOpen = { actions.onOpenWindow(line.recent.workspace.id, line.recent.item.window.id) },
            onHold = { actions.onHoldWindow(line.recent.workspace.id, line.recent.item.window.id) },
        )
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
 * The workspaces as an editor's tabs over a hairline: «Recientes» when the machine says when each
 * window was last written to, «Todos» and then one per workspace in the reader's order, the chosen
 * one underlined in the accent, counts in mono. A long press on a workspace opens its sheet, as on
 * its header. The chosen tab is brought into view whenever it changes, the first time included.
 */
@Composable
private fun WorkspaceTabRow(model: MachineModel, selection: WorkspaceTabSelection, onHold: (String) -> Unit) {
    val row = rememberLazyListState()
    val selected = selection.selected
    val recent = model.canShowRecent
    val index = remember(model.sections, selected, recent) {
        // «Recientes» leads when it is there, so every other tab moves one place along.
        val lead = if (recent) 1 else 0
        when (selected) {
            WorkspaceTabs.RECENT -> 0
            WorkspaceTabs.ALL -> lead
            else -> lead + 1 + model.sections.indexOfFirst { it.workspace.id == selected }
        }
    }
    LaunchedEffect(selected, index) { row.reveal(index) }
    val total = remember(model.sections) { model.sections.sumOf { it.windows.size } }
    val recentTotal = remember(model) { if (model.canShowRecent) model.recentWindows().size else 0 }
    Box(Modifier.fillMaxWidth()) {
        // Under the strip, so the chosen tab's underline covers it.
        Hairline(Modifier.align(Alignment.BottomStart))
        LazyRow(
            Modifier.fillMaxWidth().selectableGroup(),
            state = row,
            // A tab pads its own label, so the first name lines up with the page's edge.
            contentPadding = PaddingValues(horizontal = (UniTheme.spacing.page - TabInset).coerceAtLeast(0.dp)),
        ) {
            if (recent) item(key = "recent", contentType = "all") {
                WorkspaceTab(
                    name = stringResource(R.string.design_tab_recent), count = recentTotal, pinned = false, activity = null,
                    chosen = selection.showsRecent, onClick = { selection.select(WorkspaceTabs.RECENT) }, onHold = null,
                )
            }
            item(key = "all", contentType = "all") {
                WorkspaceTab(
                    name = stringResource(R.string.obsidiana_tab_all), count = total, pinned = false, activity = null,
                    chosen = selection.showsAll, onClick = { selection.select(WorkspaceTabs.ALL) }, onHold = null,
                )
            }
            items(model.sections, key = { "workspace:" + it.workspace.id }, contentType = { "workspace" }) { section ->
                val id = section.workspace.id
                WorkspaceTab(
                    name = section.workspace.name, count = section.windows.size, pinned = section.pinned,
                    activity = section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING },
                    chosen = id == selected, onClick = { selection.select(id) }, onHold = { onHold(id) },
                )
            }
        }
    }
}

/** How far a tab's label sits from its edges. */
private val TabInset = 12.dp

/**
 * One tab: the name, its window count in mono, the favourite star and what its AIs are doing.
 * The chosen tab is underlined in the accent and its name and count light up; the rest stay muted.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceTab(name: String, count: Int, pinned: Boolean, activity: ActivityState?, chosen: Boolean, onClick: () -> Unit, onHold: (() -> Unit)?) {
    val colors = UniTheme.colors
    val accent = colors.accent
    val spokenCount = pluralStringResource(R.plurals.window_count, count, count)
    val press = if (onHold == null) Modifier.selectable(selected = chosen, role = Role.Tab, onClick = onClick)
    else Modifier.semantics { selected = chosen }.combinedClickable(
        role = Role.Tab, onLongClickLabel = stringResource(R.string.obsidiana_workspace_options), onLongClick = onHold, onClick = onClick,
    )
    Row(
        Modifier.heightIn(min = 44.dp)
            .drawBehind {
                if (!chosen) return@drawBehind
                val bar = 2.dp.toPx()
                drawRect(accent, Offset(0f, size.height - bar), Size(size.width, bar))
            }
            .clip(UniTheme.shapes.chip).then(press).padding(horizontal = TabInset),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            name, Modifier.widthIn(max = 160.dp), style = MaterialTheme.typography.bodyMedium, fontSize = 13.sp,
            fontFamily = UniTheme.type.identifierFamily, fontWeight = if (chosen) FontWeight.SemiBold else FontWeight.Medium,
            color = if (chosen) colors.text else colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            count.toString(), Modifier.clearAndSetSemantics { contentDescription = spokenCount }, style = MaterialTheme.typography.bodySmall,
            fontFamily = ObsidianaMono, color = if (chosen) accent else colors.muted, maxLines = 1, softWrap = false,
        )
        if (pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(11.dp), tint = colors.warning)
        activity?.let { ActivityMark(it, size = 12.dp) }
    }
}

/**
 * Scrolls the tab at [index] fully into view and no further, so a tap on a tab already in sight
 * never shifts the strip under the finger.
 */
private suspend fun LazyListState.reveal(index: Int) {
    val info = layoutInfo
    // Before the first layout nothing is measured: jump straight to it.
    if (info.visibleItemsInfo.isEmpty()) { scrollToItem(index); return }
    val item = info.visibleItemsInfo.firstOrNull { it.index == index }
    val end = info.viewportEndOffset - info.afterContentPadding
    when {
        item == null -> animateScrollToItem(index)
        item.offset < 0 -> animateScrollBy(item.offset.toFloat())
        item.offset + item.size > end -> animateScrollBy((item.offset + item.size - end).toFloat())
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
 * What a single workspace's tab puts above its windows instead of the group header, whose name
 * the tab already shows: a label, its kind, the favourite star as a switch and «Nueva ventana».
 * A tap or a long press anywhere else on it opens its sheet.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WorkspaceBar(section: WorkspaceSection, onHold: () -> Unit, onTogglePin: () -> Unit, onCreateWindow: () -> Unit) {
    val colors = UniTheme.colors
    val options = stringResource(R.string.obsidiana_workspace_options)
    Row(
        Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 6.dp).heightIn(min = 44.dp).clip(UniTheme.shapes.chip)
            .combinedClickable(onClickLabel = options, onLongClickLabel = options, onLongClick = onHold, onClick = onHold)
            .padding(start = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        CapsLabel(stringResource(R.string.windows))
        // Only the remote kind is worth a badge, as on the headers under «Todos».
        if (section.workspace.isSSH == true) KindBadge(section.workspace)
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onTogglePin) {
            Icon(
                if (section.pinned) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                stringResource(if (section.pinned) R.string.box_unpin else R.string.box_pin),
                Modifier.size(18.dp), tint = if (section.pinned) colors.warning else colors.muted,
            )
        }
        if (section.canCreateWindow) NewWindowButton(onCreateWindow)
    }
}

/** «+ Nueva ventana» on a single workspace's bar: outlined and quiet beside the accent of the floating button. */
@Composable
private fun NewWindowButton(onClick: () -> Unit) {
    val colors = UniTheme.colors
    val shape = UniTheme.shapes.chip
    Row(
        Modifier.minimumInteractiveComponentSize().height(32.dp).panel(shape, colors.surface, colors.outline)
            .clickable(role = Role.Button, onClick = onClick).padding(start = 8.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Rounded.Add, null, Modifier.size(16.dp), tint = colors.text)
        Text(stringResource(R.string.new_window), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium, color = colors.text, maxLines = 1)
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

/**
 * One window under «Recientes»: the same panel row as a workspace's window, with the box of the
 * workspace it belongs to and how long ago its last prompt was written in place of its state, since
 * the list mixes every workspace and is ordered by that time.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RecentRow(recent: RecentWindow, segment: Segment, nowEpochSeconds: Long, onOpen: () -> Unit, onHold: () -> Unit) {
    val colors = UniTheme.colors
    val item = recent.item
    val waiting = item.activity == ActivityState.WAITING
    Row(
        Modifier.fillMaxWidth().panelSegment(segment, rememberSegmentShape(segment), colors.surface, colors.outline)
            .combinedClickable(onLongClickLabel = stringResource(R.string.obsidiana_window_options), onLongClick = onHold, onClick = onOpen)
            .heightIn(min = 56.dp).padding(start = 14.dp, end = 12.dp, top = 6.dp, bottom = 6.dp),
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
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    item.window.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyMedium,
                    fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(12.dp), tint = colors.warning)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                WorkspaceBox(recent.workspace.name, Modifier.weight(1f, fill = false))
                elapsedText(recent.lastPromptAt, nowEpochSeconds)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, softWrap = false)
                }
            }
        }
        when {
            // As on a workspace's window: the row already opens it, the word only says why to.
            waiting -> Text(
                stringResource(R.string.design_reply),
                Modifier.background(colors.warning.copy(alpha = .14f), UniTheme.shapes.chip).padding(horizontal = 10.dp, vertical = 6.dp),
                style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold, color = colors.warning, maxLines = 1,
            )
            item.agent != null -> Tag(item.agent)
        }
    }
}

/** The small box that names a window's workspace under «Recientes», where windows of every workspace mix. */
@Composable
private fun WorkspaceBox(name: String, modifier: Modifier = Modifier) {
    val colors = UniTheme.colors
    Text(
        name,
        modifier.widthIn(max = 180.dp).clip(UniTheme.shapes.chip).background(colors.surfaceRaised).padding(horizontal = 6.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall, fontFamily = UniTheme.type.identifierFamily, fontSize = 11.sp, lineHeight = 14.sp,
        color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
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
