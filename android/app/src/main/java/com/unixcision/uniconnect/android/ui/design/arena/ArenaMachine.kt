package com.unixcision.uniconnect.android.ui.design.arena

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.layout.layout
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
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
import com.unixcision.uniconnect.android.ui.MachineState
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
import com.unixcision.uniconnect.android.ui.design.windowLine
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme

/** How far in a window row's text starts: its padding, its mark and the gap after it. The rule between rows starts there. */
private val RowTextInset = 44.dp

/** How far in an entry of the chapter index its text sits; the underline of the chosen one runs between these insets. */
private val TabInset = 10.dp

/**
 * Arena's machine, set like a magazine's table of contents: the monogram and the machine's name
 * large in the serif with one paragraph of how it is, then the workspaces as an index of numbered
 * chapters («Todos · 01 PROYECTOS · 02 NOTBETTING…») that stays on top while the reader scrolls.
 * The chosen chapter's windows are listed underneath; «Todos» lists every chapter with its own head.
 * When the machine says when each window was last written to, «Recientes» opens the index and lists
 * the windows of every chapter by their last prompt, each with its chapter's name beside it.
 *
 * Every window is its own lazy item, so a machine with a hundred of them composes only what is on
 * screen; the card a workspace's windows share is drawn piece by piece by the rows themselves.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ArenaMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    val page = UniTheme.spacing.page
    var filter by rememberSaveable { mutableStateOf(WindowFilter.ALL) }
    // Without a connection nothing is known to work or wait, so only «Todas» makes sense.
    val shown = if (model.connected) filter else WindowFilter.ALL
    val tab = rememberWorkspaceTab(model)
    val lines = remember(model, shown, tab.selected) { arenaLines(model, shown, tab.selected) }
    val counts = remember(model, tab.selected) {
        FilterCounts(if (tab.showsRecent) model.recentWindows().map { it.item } else model.visible(tab.selected, WindowFilter.ALL).flatMap { it.windows })
    }
    val list = rememberLazyListState()
    val index = rememberLazyListState()
    // The tab the list was last set for: a rotation starts the effect below again and must not move the list.
    var listedTab by rememberSaveable(model.machine.id) { mutableStateOf(tab.selected) }
    // A new tab is read from its top: once the reader has scrolled past the index, the index comes
    // back to the top with the chosen workspace's first windows right under it.
    LaunchedEffect(tab.selected) {
        if (tab.selected == listedTab) return@LaunchedEffect
        listedTab = tab.selected
        val at = lines.indexOf(Line.Tabs)
        if (at >= 0 && list.firstVisibleItemIndex >= at) list.scrollToItem(at)
    }
    Column(Modifier.fillMaxSize()) {
        MachineBar(actions.onBack, menu)
        Box(Modifier.fillMaxWidth().weight(1f)) {
            LazyColumn(
                Modifier.fillMaxSize(),
                state = list,
                contentPadding = PaddingValues(start = page, end = page, top = 8.dp, bottom = if (model.canCreateWorkspace) 112.dp else 40.dp),
            ) {
                lines.forEach { line ->
                    if (line == Line.Tabs) stickyHeader(key = line.key, contentType = "tabs") { _ ->
                        ChapterIndex(model, tab, index, onHold = actions.onHoldWorkspace)
                    } else item(key = line.key, contentType = line::class) {
                        when (line) {
                            Line.Identity -> MachineIdentity(model)
                            Line.Offline -> MachineOfflineCard(model, actions.onConnect, Modifier.padding(top = 24.dp))
                            Line.Stale -> MachineStaleBanner(model, actions.onConnect, Modifier.padding(top = 20.dp))
                            Line.Heading -> ArenaSectionTitle(stringResource(R.string.design_workspaces), Modifier.padding(top = 28.dp))
                            Line.Tabs -> Unit
                            Line.Filters -> FilterTabs(counts, shown) { filter = it }
                            Line.LocalOnly -> Text(
                                stringResource(R.string.box_local_only), Modifier.padding(top = 8.dp),
                                style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning,
                            )
                            Line.NoWorkspaces -> Quiet(stringResource(R.string.no_workspaces))
                            Line.NoneFiltered -> Quiet(stringResource(R.string.design_no_filtered_windows))
                            is Line.Chapter -> ChapterHead(
                                line,
                                onHold = { actions.onHoldWorkspace(line.section.workspace.id) },
                                onCreateWindow = if (line.section.canCreateWindow) ({ actions.onCreateWindow(line.section.workspace.id) }) else null,
                            )
                            is Line.Folio -> ChapterFolio(
                                line.section,
                                onHold = { actions.onHoldWorkspace(line.section.workspace.id) },
                                onTogglePin = { actions.onToggleWorkspacePin(line.section.workspace.id) },
                                onCreateWindow = if (line.section.canCreateWindow) ({ actions.onCreateWindow(line.section.workspace.id) }) else null,
                            )
                            is Line.Window -> WindowRow(
                                line,
                                onOpen = { actions.onOpenWindow(line.section.workspace.id, line.item.window.id) },
                                onHold = { actions.onHoldWindow(line.section.workspace.id, line.item.window.id) },
                            )
                            is Line.Recent -> RecentRow(
                                line, model.nowEpochSeconds,
                                onOpen = { actions.onOpenWindow(line.recent.workspace.id, line.recent.item.window.id) },
                                onHold = { actions.onHoldWindow(line.recent.workspace.id, line.recent.item.window.id) },
                            )
                            is Line.Empty -> EmptyChapter()
                            Line.Notices -> Box(Modifier.padding(top = 28.dp)) {
                                NotificationConnectionCard(model.noticeLink, model.connected, actions.onEnableNotices, actions.onDisableNotices)
                            }
                        }
                    }
                }
            }
            if (model.canCreateWorkspace) NewWorkspaceButton(
                list, actions.onCreateWorkspace, Modifier.align(Alignment.BottomEnd).padding(end = 20.dp, bottom = 24.dp),
            )
        }
    }
}

/** One item of the machine's list. Keys stay the same across refreshes, so rows keep their place. */
private sealed interface Line {
    val key: Any

    data object Identity : Line { override val key: Any = "identity" }
    data object Offline : Line { override val key: Any = "offline" }
    data object Stale : Line { override val key: Any = "stale" }
    data object Heading : Line { override val key: Any = "heading" }

    /** The chapter index; the list keeps it on top while the reader scrolls. */
    data object Tabs : Line { override val key: Any = "tabs" }
    data object Filters : Line { override val key: Any = "filters" }
    data object LocalOnly : Line { override val key: Any = "local-only" }
    data object NoWorkspaces : Line { override val key: Any = "no-workspaces" }
    data object NoneFiltered : Line { override val key: Any = "none-filtered" }
    data object Notices : Line { override val key: Any = "notices" }

    /** A workspace's heading; [number] is its place among all of them, so a filter never renumbers. */
    data class Chapter(val section: WorkspaceSection, val number: Int, val first: Boolean) : Line {
        override val key: Any get() = "ws:${section.workspace.id}"
    }

    /** The head of the one chapter its tab shows; [section] holds all its windows, whatever the filter keeps. */
    data class Folio(val section: WorkspaceSection) : Line {
        override val key: Any get() = "folio:${section.workspace.id}"
    }

    /** One window; [first] and [last] say which corners of its workspace's card it draws. */
    data class Window(val section: WorkspaceSection, val item: WindowItem, val first: Boolean, val last: Boolean) : Line {
        override val key: Any get() = "win:${section.workspace.id}:${item.window.id}"
    }

    data class Empty(val section: WorkspaceSection) : Line {
        override val key: Any get() = "empty:${section.workspace.id}"
    }

    /** One window under «Recientes»; [first] and [last] say which corners it draws of the one card they all share. */
    data class Recent(val recent: RecentWindow, val first: Boolean, val last: Boolean) : Line {
        override val key: Any get() = "recent:${recent.workspace.id}:${recent.item.window.id}"
    }
}

/**
 * The list the machine screen draws, in order, for [filter] in [tab]: every chapter with its head
 * under «Todos», or the chosen one under its folio, which stays even when the filter empties it.
 * «Recientes» has no heads at all: one card of windows, the last written to first.
 */
private fun arenaLines(model: MachineModel, filter: WindowFilter, tab: String): List<Line> = buildList {
    add(Line.Identity)
    if (!model.hasSnapshot) {
        add(Line.Offline)
        if (model.connected || model.noticeLink != null) add(Line.Notices)
        return@buildList
    }
    if (!model.connected) add(Line.Stale)
    add(Line.Heading)
    if (model.hostKeepsOrder == false) add(Line.LocalOnly)
    if (model.sections.isEmpty()) add(Line.NoWorkspaces)
    else {
        add(Line.Tabs)
        if (model.connected) add(Line.Filters)
    }
    if (tab == WorkspaceTabs.RECENT) {
        val recent = model.recentWindows(filter)
        if (recent.isEmpty()) add(Line.NoneFiltered)
        recent.forEachIndexed { at, window -> add(Line.Recent(window, first = at == 0, last = at == recent.lastIndex)) }
        if (model.connected || model.noticeLink != null) add(Line.Notices)
        return@buildList
    }
    // A tab that names no workspace reads as «Todos», as the index marks it.
    val single = model.sections.firstOrNull { it.workspace.id == tab }
    val sections = model.visible(single?.workspace?.id ?: WorkspaceTabs.ALL, filter)
    if (single != null) {
        add(Line.Folio(single))
        val section = sections.firstOrNull()
        when {
            section == null -> add(Line.NoneFiltered)
            section.windows.isEmpty() -> add(Line.Empty(section))
            else -> addWindows(section)
        }
    } else {
        val numbers = model.sections.withIndex().associate { (index, section) -> section.workspace.id to index + 1 }
        if (model.sections.isNotEmpty() && sections.isEmpty()) add(Line.NoneFiltered)
        sections.forEachIndexed { index, section ->
            add(Line.Chapter(section, numbers[section.workspace.id] ?: index + 1, first = index == 0))
            if (section.windows.isEmpty()) add(Line.Empty(section))
            addWindows(section)
        }
    }
    if (model.connected || model.noticeLink != null) add(Line.Notices)
}

/** A row per window of [section], each knowing whether it opens or closes the card they share. */
private fun MutableList<Line>.addWindows(section: WorkspaceSection) {
    section.windows.forEachIndexed { at, item ->
        add(Line.Window(section, item, first = at == 0, last = at == section.windows.lastIndex))
    }
}

/** How many of the chosen tab's [windows] each filter keeps, counted the way the filter itself picks them. */
private class FilterCounts(windows: List<WindowItem>) {
    val all: Int = windows.size
    val working: Int = windows.count { WindowFilter.WORKING.accepts(it.activity) }
    val waiting: Int = windows.count { WindowFilter.WAITING.accepts(it.activity) }
}

/** «‹ Máquinas» on the left and the machine's menu on the right. */
@Composable
private fun MachineBar(onBack: () -> Unit, menu: @Composable () -> Unit) {
    val colors = UniTheme.colors
    Row(Modifier.fillMaxWidth().height(56.dp).padding(start = 6.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.height(44.dp).clip(UniTheme.shapes.button).clickable(role = Role.Button, onClick = onBack).padding(start = 2.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, stringResource(R.string.back), Modifier.size(26.dp), tint = colors.text)
            Text(
                stringResource(R.string.design_back_machines), style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp),
                fontWeight = FontWeight.Medium, color = colors.text, maxLines = 1,
            )
        }
        Spacer(Modifier.weight(1f))
        menu()
    }
}

/** The machine as a feature opens: monogram, link and address, the name set large and the paragraph. */
@Composable
private fun MachineIdentity(model: MachineModel) {
    val colors = UniTheme.colors
    val state = when {
        model.connected -> MachineState.CONNECTED
        model.checking -> MachineState.CHECKING
        else -> MachineState.SAVED
    }
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ArenaMonogram(model.machine.name, 64.dp, UniTheme.shapes.card, dimmed = !model.connected)
            Column(Modifier.weight(1f).padding(start = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                ArenaStateChip(state)
                Text(
                    model.machine.endpoint.displayAddress, style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
                    fontFamily = UniTheme.type.identifierFamily, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Text(
            model.machine.name, Modifier.padding(top = 18.dp),
            style = MaterialTheme.typography.displaySmall.copy(fontSize = 36.sp, lineHeight = 40.sp, letterSpacing = (-0.9).sp),
            fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
            maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
        if (model.hasSnapshot) Text(
            arenaActivityProse(model.summary.windows, model.summary.working, model.summary.waiting, live = model.connected),
            Modifier.padding(top = 10.dp), style = arenaProseStyle(),
        )
    }
}

/**
 * The workspaces as the magazine's contents: «Recientes» when the machine dates its prompts,
 * «Todos», then each chapter with its number in the serif, its name, its favourite and AI marks and
 * how many windows it has, parted by small dots. The chosen entry is set in terracotta and
 * underlined; a long press on a chapter opens its sheet. It runs to the screen's edges over a
 * hairline, and brings the chosen entry into view.
 */
@Composable
private fun ChapterIndex(model: MachineModel, tab: WorkspaceTabSelection, row: LazyListState, onHold: (String) -> Unit) {
    val colors = UniTheme.colors
    val page = UniTheme.spacing.page
    val sections = model.sections
    // «Recientes» leads when offered, and every entry after it moves one place along.
    val recent = model.canShowRecent
    val lead = if (recent) 1 else 0
    val recentCount = remember(model) { model.recentWindows().size }
    val chosen = when {
        tab.showsRecent -> 0
        tab.showsAll -> lead
        else -> sections.indexOfFirst { it.workspace.id == tab.selected } + 1 + lead
    }
    // An entry already whole on screen stays where the reader left the index; one off screen (the
    // screen opening on it, a notice picking it) is scrolled to, at once before the first layout.
    LaunchedEffect(tab.selected, chosen) {
        val info = row.layoutInfo
        val entry = info.visibleItemsInfo.firstOrNull { it.index == chosen }
        val whole = entry != null && entry.offset >= info.viewportStartOffset && entry.offset + entry.size <= info.viewportEndOffset
        if (info.visibleItemsInfo.isEmpty()) row.scrollToItem(chosen)
        else if (!whole) row.animateScrollToItem(chosen)
    }
    val hairline = colors.outline
    LazyRow(
        Modifier.bleed(page)
            .fillMaxWidth()
            .background(colors.background)
            .drawBehind {
                val stroke = 1.dp.toPx()
                drawLine(hairline, Offset(0f, size.height - stroke / 2), Offset(size.width, size.height - stroke / 2), stroke)
            }
            .selectableGroup(),
        state = row,
        contentPadding = PaddingValues(horizontal = page - TabInset),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (recent) item(key = "tab:${WorkspaceTabs.RECENT}", contentType = "recent") {
            val on = tab.showsRecent
            IndexTab(on, separated = false, onClick = { tab.select(WorkspaceTabs.RECENT) }, onLongClick = null) {
                Text(
                    stringResource(R.string.design_tab_recent), style = MaterialTheme.typography.titleSmall.copy(fontSize = 15.sp, lineHeight = 20.sp),
                    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
                    color = if (on) colors.accent else colors.text, maxLines = 1,
                )
                TabCount(recentCount, on)
            }
        }
        item(key = "tab:${WorkspaceTabs.ALL}", contentType = "all") {
            val on = tab.showsAll
            IndexTab(on, separated = recent, onClick = { tab.select(WorkspaceTabs.ALL) }, onLongClick = null) {
                Text(
                    stringResource(R.string.arena_tab_all), style = MaterialTheme.typography.titleSmall.copy(fontSize = 15.sp, lineHeight = 20.sp),
                    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
                    color = if (on) colors.accent else colors.text, maxLines = 1,
                )
                TabCount(sections.sumOf { it.windows.size }, on)
            }
        }
        itemsIndexed(sections, key = { _, section -> "tab:ws:${section.workspace.id}" }, contentType = { _, _ -> "chapter" }) { at, section ->
            val on = chosen == at + 1 + lead
            val id = section.workspace.id
            IndexTab(on, separated = true, onClick = { tab.select(id) }, onLongClick = { onHold(id) }) {
                Text(
                    (at + 1).toString().padStart(2, '0'),
                    style = MaterialTheme.typography.labelLarge.copy(fontSize = 13.sp, lineHeight = 18.sp),
                    fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold,
                    color = if (on) colors.accent else colors.muted, maxLines = 1,
                )
                Text(
                    section.workspace.name, Modifier.widthIn(max = 148.dp),
                    style = MaterialTheme.typography.titleSmall.copy(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = .75.sp),
                    fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold,
                    color = if (on) colors.accent else colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (section.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(12.dp), tint = colors.warning)
                section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING }?.let {
                    ActivityMark(it, size = 13.dp, tone = colors.success)
                }
                TabCount(section.windows.size, on)
            }
        }
    }
}

/**
 * One entry of the chapter index, at least 48 dp tall. When [chosen] a terracotta underline runs
 * under its text; [separated] sets the dot that parts it from the entry before, in the gap between.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun IndexTab(
    chosen: Boolean,
    separated: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)?,
    content: @Composable RowScope.() -> Unit,
) {
    val colors = UniTheme.colors
    val underline = colors.accent
    val dot = colors.muted.copy(alpha = .5f)
    Row(
        Modifier
            .drawBehind {
                if (separated) drawCircle(dot, radius = 1.5.dp.toPx(), center = Offset(0f, size.height / 2))
                if (chosen) {
                    val stroke = 2.dp.toPx()
                    val inset = TabInset.toPx()
                    val y = size.height - stroke / 2
                    drawLine(underline, Offset(inset, y), Offset(size.width - inset, y), stroke, cap = StrokeCap.Round)
                }
            }
            .clip(UniTheme.shapes.chip)
            .semantics { selected = chosen }
            .combinedClickable(role = Role.Tab, onLongClick = onLongClick, onClick = onClick)
            .height(48.dp)
            .padding(horizontal = TabInset),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        content = content,
    )
}

/** How many windows an entry of the index holds, small beside its name. */
@Composable
private fun TabCount(count: Int, chosen: Boolean) {
    val colors = UniTheme.colors
    Text(
        count.toString(), style = MaterialTheme.typography.labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp),
        fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Medium,
        color = if (chosen) colors.accent.copy(alpha = .75f) else colors.muted, maxLines = 1,
    )
}

/**
 * Widens a row set inside the list's side margins by [margin] on each side, so it runs to the
 * screen's edges and its content scrolls under them.
 */
private fun Modifier.bleed(margin: Dp): Modifier = layout { measurable, constraints ->
    val extra = margin.roundToPx() * 2
    val wide = if (constraints.hasBoundedWidth) constraints.copy(minWidth = constraints.minWidth + extra, maxWidth = constraints.maxWidth + extra) else constraints
    val placeable = measurable.measure(wide)
    // Reported wider than its constraints, the row is centred over them by its parent: [margin]
    // past each side, and its touches reach the edges too, which an offset inside a narrower
    // node would not.
    layout(placeable.width, placeable.height) { placeable.place(0, 0) }
}

/** While the machine answers, the tabs that keep only who works or who waits in the chosen tab. */
@Composable
private fun FilterTabs(counts: FilterCounts, filter: WindowFilter, onFilter: (WindowFilter) -> Unit) {
    Row(
        Modifier.padding(top = 14.dp).horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        FilterTab(stringResource(R.string.window_filter_all), counts.all, filter == WindowFilter.ALL, null) { onFilter(WindowFilter.ALL) }
        FilterTab(stringResource(R.string.window_filter_working), counts.working, filter == WindowFilter.WORKING, null) { onFilter(WindowFilter.WORKING) }
        FilterTab(
            stringResource(R.string.window_filter_waiting), counts.waiting, filter == WindowFilter.WAITING,
            UniTheme.colors.warning.takeIf { counts.waiting > 0 },
        ) { onFilter(WindowFilter.WAITING) }
    }
}

/** One filter tab: ink filled when chosen, a hairline otherwise, with its count beside the name. */
@Composable
private fun FilterTab(label: String, count: Int, selected: Boolean, tone: Color?, onClick: () -> Unit) {
    val colors = UniTheme.colors
    val shape = UniTheme.shapes.chip
    val ink = if (selected) colors.background else colors.text
    Row(
        Modifier.minimumInteractiveComponentSize()
            .clip(shape)
            .then(if (selected) Modifier.background(colors.text) else Modifier.border(1.dp, colors.outline, shape))
            .selectable(selected = selected, role = Role.Tab, onClick = onClick)
            .height(36.dp)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            label, style = MaterialTheme.typography.labelLarge.copy(fontSize = 14.sp),
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = ink, maxLines = 1,
        )
        Text(
            count.toString(), style = MaterialTheme.typography.labelLarge.copy(fontSize = 14.sp),
            fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold,
            color = if (selected) ink.copy(alpha = .7f) else tone ?: colors.muted, maxLines = 1,
        )
    }
}

/**
 * A workspace as a chapter: its number in the serif, its name, favourite and AI marks, a rule to
 * the edge and the «+» that opens a window in it; underneath, how many windows it has. A long
 * press opens its sheet (favourite, order, relaunch).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChapterHead(line: Line.Chapter, onHold: () -> Unit, onCreateWindow: (() -> Unit)?) {
    val colors = UniTheme.colors
    val section = line.section
    val count = section.windows.size
    Row(
        Modifier.fillMaxWidth()
            .padding(top = if (line.first) 12.dp else 24.dp, bottom = 6.dp)
            .clip(UniTheme.shapes.chip)
            .combinedClickable(onClick = {}, onLongClick = onHold)
            .heightIn(min = 44.dp),
    ) {
        Text(
            line.number.toString().padStart(2, '0'), Modifier.width(28.dp).padding(top = 2.dp),
            style = MaterialTheme.typography.labelLarge.copy(fontSize = 13.sp, lineHeight = 18.sp),
            fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.muted, maxLines = 1,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    section.workspace.name, Modifier.weight(3f, fill = false),
                    style = MaterialTheme.typography.titleSmall.copy(fontSize = 15.sp, lineHeight = 20.sp, letterSpacing = .75.sp),
                    fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, color = colors.text,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (section.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
                section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING }?.let {
                    ActivityMark(it, size = 14.dp, tone = colors.success)
                }
                Box(Modifier.weight(1f).height(1.dp).background(colors.outline))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    pluralStringResource(R.plurals.window_count, count, count),
                    style = MaterialTheme.typography.bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp), color = colors.muted, maxLines = 1,
                )
                // Only the remote kind is worth a badge: a local box is the default and says nothing.
                if (section.workspace.isSSH == true) KindBadge(section.workspace)
            }
        }
        if (onCreateWindow != null) IconButton(onClick = onCreateWindow, Modifier.align(Alignment.CenterVertically)) {
            Icon(Icons.Rounded.Add, stringResource(R.string.new_window), tint = colors.accent)
        }
    }
}

/**
 * The head of the one chapter its tab shows, like a magazine's running head: the index already
 * names it, so only how many windows it has and its kind, a rule to the edge, the star that makes
 * it a favourite and the «+» that opens a window in it. A long press opens its sheet, as on a
 * chapter's full head.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChapterFolio(section: WorkspaceSection, onHold: () -> Unit, onTogglePin: () -> Unit, onCreateWindow: (() -> Unit)?) {
    val colors = UniTheme.colors
    val count = section.windows.size
    Row(
        Modifier.fillMaxWidth()
            .padding(top = 8.dp, bottom = 6.dp)
            .clip(UniTheme.shapes.chip)
            .combinedClickable(onClick = {}, onLongClick = onHold)
            .heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            pluralStringResource(R.plurals.window_count, count, count),
            style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp), color = colors.muted, maxLines = 1,
        )
        // Only the remote kind is worth a badge: a local box is the default and says nothing.
        if (section.workspace.isSSH == true) KindBadge(section.workspace)
        Box(Modifier.weight(1f).height(1.dp).background(colors.outline))
        IconButton(onClick = onTogglePin) {
            Icon(
                if (section.pinned) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                stringResource(if (section.pinned) R.string.box_unpin else R.string.box_pin),
                Modifier.size(20.dp), tint = if (section.pinned) colors.warning else colors.muted,
            )
        }
        if (onCreateWindow != null) IconButton(onClick = onCreateWindow) {
            Icon(Icons.Rounded.Add, stringResource(R.string.new_window), tint = colors.accent)
        }
    }
}

/**
 * One window: the AI's mark, the name and «Claude · Trabajando» under it, and a «Responder» when
 * it waits for the reader. Without a connection the item has no activity and nothing is drawn
 * for it: a list read earlier must not look busy.
 */
@Composable
private fun WindowRow(line: Line.Window, onOpen: () -> Unit, onHold: () -> Unit) {
    val colors = UniTheme.colors
    val item = line.item
    WindowCard(item, line.first, line.last, onOpen, onHold) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            WindowName(item, Modifier.weight(1f, fill = false))
            if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(13.dp), tint = colors.warning)
        }
        windowLineStyled(item)?.let { text -> WindowDetail(text) }
    }
}

/**
 * One window under «Recientes»: the same row as in a chapter, with the chapter it belongs to in a
 * small box beside its name, and how long ago the reader last wrote to it ahead of the AI's line.
 */
@Composable
private fun RecentRow(line: Line.Recent, nowEpochSeconds: Long, onOpen: () -> Unit, onHold: () -> Unit) {
    val colors = UniTheme.colors
    val item = line.recent.item
    val ago = elapsedText(line.recent.lastPromptAt, nowEpochSeconds)
    val state = windowLineStyled(item)
    WindowCard(item, line.first, line.last, onOpen, onHold, Modifier.padding(top = if (line.first) 12.dp else 0.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            WindowName(item, Modifier.weight(1f, fill = false))
            if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(13.dp), tint = colors.warning)
            WorkspaceTag(line.recent.workspace.name)
        }
        val text = buildAnnotatedString {
            ago?.let { append(it) }
            if (state != null) {
                if (ago != null) append(" · ")
                append(state)
            }
        }
        if (text.isNotEmpty()) WindowDetail(text)
    }
}

/**
 * The frame every window row shares: its piece of the card, the AI's mark in front, a «Responder»
 * when it waits and a chevron otherwise; [content] is the name and the lines under it.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowCard(
    item: WindowItem,
    first: Boolean,
    last: Boolean,
    onOpen: () -> Unit,
    onHold: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = UniTheme.colors
    val waiting = item.activity == ActivityState.WAITING
    val radius = UniTheme.shapes.cardRadius
    val edge = colors.outline
    val shape = ContinuousRoundedShape(
        topStart = if (first) radius else 0.dp, topEnd = if (first) radius else 0.dp,
        bottomEnd = if (last) radius else 0.dp, bottomStart = if (last) radius else 0.dp,
    )
    Row(
        modifier.fillMaxWidth()
            .chapterCard(first, last, radius, colors.surface, edge)
            .clip(shape)
            .then(if (waiting) Modifier.background(colors.warning.copy(alpha = .07f)) else Modifier)
            .then(
                if (first) Modifier
                else Modifier.drawBehind {
                    val stroke = 1.dp.toPx()
                    drawLine(edge, Offset(RowTextInset.toPx(), stroke / 2), Offset(size.width, stroke / 2), stroke)
                },
            )
            .combinedClickable(onClick = onOpen, onLongClick = onHold)
            .heightIn(min = if (waiting) 72.dp else 64.dp)
            .padding(start = 16.dp, end = 12.dp, top = 10.dp, bottom = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
            val activity = item.activity
            if (activity == ActivityState.IDLE) Box(Modifier.size(10.dp).background(colors.muted.copy(alpha = .5f), CircleShape))
            else if (activity != null) ActivityMark(activity, size = 16.dp, tone = colors.success)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
        if (waiting) ArenaReplyButton(onOpen)
        else Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(20.dp), tint = colors.muted)
    }
}

/** A window's name, set in the identifier face. */
@Composable
private fun WindowName(item: WindowItem, modifier: Modifier) {
    Text(
        item.window.name, modifier,
        style = MaterialTheme.typography.bodyMedium.copy(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = .3.sp),
        fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, color = UniTheme.colors.text,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** The small line under a window's name. */
@Composable
private fun WindowDetail(text: AnnotatedString) {
    Text(
        text, style = MaterialTheme.typography.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp),
        color = UniTheme.colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/**
 * The chapter a recent window belongs to, in a small box set in the identifier face: under
 * «Recientes» rows from every chapter sit together, and this is what tells them apart.
 */
@Composable
private fun WorkspaceTag(name: String) {
    Text(
        name,
        Modifier.widthIn(max = 132.dp).background(UniTheme.colors.surfaceRaised, UniTheme.shapes.chip).padding(horizontal = 7.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp, lineHeight = 15.sp, letterSpacing = .5.sp),
        fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Medium, color = UniTheme.colors.muted,
        maxLines = 1, overflow = TextOverflow.Ellipsis,
    )
}

/** [windowLine] with its state in colour: green while the AI works, the warning tone while it waits. */
@Composable
private fun windowLineStyled(item: WindowItem): AnnotatedString? {
    val line = windowLine(item) ?: return null
    val state = activityText(item.activity)
    val colors = UniTheme.colors
    val tone = when (item.activity) {
        ActivityState.WORKING -> colors.success
        ActivityState.WAITING -> colors.warning
        else -> null
    }
    if (state == null || tone == null || !line.endsWith(state)) return AnnotatedString(line)
    return buildAnnotatedString {
        append(line.dropLast(state.length))
        withStyle(SpanStyle(color = tone, fontWeight = if (item.activity == ActivityState.WAITING) FontWeight.SemiBold else FontWeight.Medium)) {
            append(state)
        }
    }
}

/** A workspace with no windows: one line inside its own card. */
@Composable
private fun EmptyChapter() {
    val colors = UniTheme.colors
    Text(
        stringResource(R.string.no_windows),
        Modifier.fillMaxWidth().chapterCard(first = true, last = true, UniTheme.shapes.cardRadius, colors.surface, colors.outline)
            .padding(horizontal = 16.dp, vertical = 18.dp),
        style = MaterialTheme.typography.bodyMedium, color = colors.muted,
    )
}

/** A quiet line in the list: no workspaces, or none in the chosen state. */
@Composable
private fun Quiet(text: String) {
    Text(text, Modifier.padding(top = 16.dp), style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
}

/**
 * «Nuevo espacio de trabajo», the ink button in the corner. It folds to its «+» once the reader
 * scrolls into the chapters, so it hides less of them.
 */
@Composable
private fun NewWorkspaceButton(list: LazyListState, onClick: () -> Unit, modifier: Modifier) {
    val colors = UniTheme.colors
    val expanded by remember(list) { derivedStateOf { list.firstVisibleItemIndex == 0 } }
    val label = stringResource(R.string.new_workspace)
    ExtendedFloatingActionButton(
        text = { Text(label, fontWeight = FontWeight.SemiBold, maxLines = 1) },
        icon = { Icon(Icons.Rounded.Add, if (expanded) null else label) },
        onClick = onClick,
        modifier = modifier,
        expanded = expanded,
        shape = UniTheme.shapes.materialButton,
        containerColor = colors.text,
        contentColor = colors.background,
    )
}

/**
 * The part of a workspace's card that one row draws: the fill and the hairline edge, rounded only
 * where the card starts or ends. An open side is drawn as if the card went on and then clipped
 * away, so the rows of one workspace join into a single card without a shadow per row.
 */
private fun Modifier.chapterCard(first: Boolean, last: Boolean, radius: Dp, fill: Color, edge: Color): Modifier = drawWithCache {
    val stroke = 1.dp.toPx()
    val reach = radius.toPx() * 2
    val top = if (first) 0f else -reach
    val bottom = if (last) size.height else size.height + reach
    // Never negative: the shape coerces its radius into a range that a negative size would empty.
    val area = Size((size.width - stroke).coerceAtLeast(0f), (bottom - top - stroke).coerceAtLeast(0f))
    val outline = ContinuousRoundedShape(radius).createOutline(area, layoutDirection, this)
    val hairline = Stroke(stroke)
    onDrawBehind {
        clipRect {
            translate(left = stroke / 2, top = top + stroke / 2) {
                drawOutline(outline, fill)
                drawOutline(outline, edge, style = hairline)
            }
        }
    }
}
