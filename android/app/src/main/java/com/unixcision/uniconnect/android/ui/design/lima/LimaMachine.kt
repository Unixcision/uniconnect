package com.unixcision.uniconnect.android.ui.design.lima

import androidx.annotation.StringRes
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
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
import androidx.compose.ui.unit.em
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
import com.unixcision.uniconnect.android.ui.theme.continuousTop

/**
 * Lima's machine screen: the machine with its state chip, a strip of workspace tiles that work as
 * tabs, a bento of three numbers (windows, working, waiting) for the picked tab that double as the
 * filter, and the tab's windows in one block, or every workspace as its own block under «Todos».
 * «Recientes», first when the host says when each window was last written to, lists the windows
 * of every workspace in one block, the most recent first. A window that waits for the reader is
 * tinted and offers «Responder».
 *
 * A block is drawn in slices (its head, one slice per window, the last one rounding the foot) so
 * the list stays lazy: a machine with a hundred windows composes only what is on screen.
 */
@Composable
fun LimaMachine(model: MachineModel, actions: MachineActions, menu: @Composable () -> Unit) {
    val page = UniTheme.spacing.page
    var filter by rememberSaveable { mutableStateOf(WindowFilter.ALL) }
    // Without a live connection no window has a state, so only "all" can show anything.
    val shown = if (model.connected) filter else WindowFilter.ALL
    val tab = rememberWorkspaceTab(model)
    val entries = remember(model, shown, tab.selected) { limaEntries(model, shown, tab.selected) }
    // What the bento counts: the recent windows, the picked workspace's, or all of them.
    val scope = remember(model, tab.selected) {
        if (tab.showsRecent) model.recentWindows().map { it.item }
        else model.sections.filter { tab.showsAll || it.workspace.id == tab.selected }.flatMap { it.windows }
    }
    val list = rememberLazyListState()
    // Held here so the strip keeps its place while the list scrolls it away and back.
    val strip = rememberLazyListState()
    LaunchedEffect(model.focusWorkspaceID, model.sections.isNotEmpty()) {
        val id = model.focusWorkspaceID ?: return@LaunchedEffect
        // A notice may name a workspace whose windows the filter hides: show them all rather than nothing.
        if (model.sections.any { it.workspace.id == id } && model.visible(id, shown).isEmpty()) filter = WindowFilter.ALL
    }
    // The tab the list was last scrolled for; saved so coming back from a window keeps the list where it was.
    var listedTab by rememberSaveable { mutableStateOf(tab.selected) }
    LaunchedEffect(tab.selected) {
        if (tab.selected == listedTab) return@LaunchedEffect
        listedTab = tab.selected
        // Another tab is another list: start it from its top, with the strip still in view.
        val tabs = entries.indexOf(LimaEntry.Tabs)
        val past = list.firstVisibleItemIndex > tabs || (list.firstVisibleItemIndex == tabs && list.firstVisibleItemScrollOffset > 0)
        if (tabs >= 0 && past) list.scrollToItem(tabs)
    }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            LimaMachineBar(actions.onBack, menu)
            LazyColumn(
                Modifier.fillMaxSize(),
                state = list,
                contentPadding = PaddingValues(start = page, end = page, bottom = if (model.canCreateWorkspace) 104.dp else 32.dp),
            ) {
                items(entries, key = { it.key }, contentType = { it::class }) { entry ->
                    when (entry) {
                        LimaEntry.Identity -> LimaIdentity(model)
                        LimaEntry.Offline -> MachineOfflineCard(model, actions.onConnect, Modifier.padding(top = 18.dp))
                        LimaEntry.Stale -> MachineStaleBanner(model, actions.onConnect, Modifier.padding(top = 14.dp))
                        LimaEntry.Metrics -> LimaMetrics(model, scope) { filter = it }
                        LimaEntry.Spaces -> LimaSpacesLabel(model)
                        LimaEntry.Tabs -> LimaTabs(model, tab, strip, actions.onHoldWorkspace)
                        LimaEntry.Filter -> LimaFilter(shown) { filter = it }
                        LimaEntry.NoWorkspaces -> LimaNote(stringResource(R.string.no_workspaces))
                        LimaEntry.NoMatches -> LimaNote(stringResource(R.string.design_no_filtered_windows))
                        is LimaEntry.Head -> if (entry.named) LimaSectionHead(entry.section, actions) else LimaTabHead(entry.section, actions)
                        is LimaEntry.Window -> LimaWindowRow(entry.section, entry.item, entry.last, actions)
                        is LimaEntry.Recent -> LimaRecentRow(entry.recent, entry.first, entry.last, model.nowEpochSeconds, actions)
                        is LimaEntry.Empty -> LimaEmptySection(stringResource(entry.note))
                        LimaEntry.Notices -> Box(Modifier.padding(top = 22.dp)) {
                            NotificationConnectionCard(model.noticeLink, model.connected, actions.onEnableNotices, actions.onDisableNotices)
                        }
                    }
                }
            }
        }
        if (model.canCreateWorkspace) LimaNewWorkspaceButton(
            actions.onCreateWorkspace,
            Modifier.align(Alignment.BottomEnd).padding(end = page - 6.dp, bottom = 14.dp),
        )
    }
}

/** One item of the machine list; a workspace comes as its head and one item per window. */
private sealed interface LimaEntry {
    val key: String

    data object Identity : LimaEntry { override val key = "identity" }
    data object Offline : LimaEntry { override val key = "offline" }
    data object Stale : LimaEntry { override val key = "stale" }
    data object Metrics : LimaEntry { override val key = "metrics" }
    data object Spaces : LimaEntry { override val key = "spaces" }
    data object Tabs : LimaEntry { override val key = "tabs" }
    data object Filter : LimaEntry { override val key = "filter" }
    data object NoWorkspaces : LimaEntry { override val key = "no-workspaces" }
    data object NoMatches : LimaEntry { override val key = "no-matches" }
    data object Notices : LimaEntry { override val key = "notices" }

    /** A block's head; [named] is false under a workspace's own tab, which already says its name. */
    data class Head(val section: WorkspaceSection, val named: Boolean) : LimaEntry {
        override val key get() = "ws:${section.workspace.id}"
    }
    data class Window(val section: WorkspaceSection, val item: WindowItem, val last: Boolean) : LimaEntry {
        override val key get() = "win:${section.workspace.id}:${item.window.id}"
    }
    data class Empty(val section: WorkspaceSection, @StringRes val note: Int) : LimaEntry {
        override val key get() = "empty:${section.workspace.id}"
    }

    /** One window under «Recientes»; [first] and [last] round the single block they all share. */
    data class Recent(val recent: RecentWindow, val first: Boolean, val last: Boolean) : LimaEntry {
        override val key get() = "r:${recent.workspace.id}/${recent.item.window.id}"
    }
}

/**
 * The list in display order for [tab] and [filter]; pure, so it is remembered and the tab effect
 * finds the strip in it. The strip comes before the bento because the bento counts the picked tab.
 */
private fun limaEntries(model: MachineModel, filter: WindowFilter, tab: String): List<LimaEntry> = buildList {
    add(LimaEntry.Identity)
    if (!model.hasSnapshot) {
        add(LimaEntry.Offline)
    } else {
        if (!model.connected) add(LimaEntry.Stale)
        if (model.sections.isEmpty()) {
            add(LimaEntry.Metrics)
            add(LimaEntry.Spaces)
            add(LimaEntry.NoWorkspaces)
        } else {
            val recent = tab == WorkspaceTabs.RECENT
            val single = if (recent) null else model.sections.firstOrNull { it.workspace.id == tab }
            add(LimaEntry.Spaces)
            add(LimaEntry.Tabs)
            // Without an answer the bento only counts windows, and a workspace's count is already on its tab.
            if (model.connected || single == null) add(LimaEntry.Metrics)
            if (model.connected) add(LimaEntry.Filter)
            if (recent) {
                // One block for every workspace's windows: the box on each row says where it lives.
                val windows = model.recentWindows(filter)
                if (windows.isEmpty()) add(LimaEntry.NoMatches)
                windows.forEachIndexed { index, window -> add(LimaEntry.Recent(window, first = index == 0, last = index == windows.lastIndex)) }
            } else {
                val visible = model.visible(tab, filter)
                if (single == null && visible.isEmpty()) add(LimaEntry.NoMatches)
                // A tab keeps its block when the filter empties it, so «+», the star and the sheet stay at hand.
                val blocks = if (single == null) visible else listOf(visible.firstOrNull() ?: single.copy(windows = emptyList()))
                blocks.forEach { section ->
                    add(LimaEntry.Head(section, named = single == null))
                    if (section.windows.isEmpty()) {
                        add(LimaEntry.Empty(section, if (section.workspace.windows.isEmpty()) R.string.no_windows else R.string.design_no_filtered_windows))
                    }
                    section.windows.forEachIndexed { index, item -> add(LimaEntry.Window(section, item, last = index == section.windows.lastIndex)) }
                }
            }
        }
    }
    if (model.connected || model.noticeLink != null) add(LimaEntry.Notices)
}

/** Back on the left; the machine's own menu (edit, relaunch every AI, remove) on the right. */
@Composable
private fun LimaMachineBar(onBack: () -> Unit, menu: @Composable () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = UniTheme.spacing.page, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LimaSquareButton(Icons.AutoMirrored.Rounded.ArrowBack, stringResource(R.string.back), onBack)
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(44.dp).clip(UniTheme.shapes.button).background(UniTheme.colors.surface), contentAlignment = Alignment.Center) { menu() }
    }
}

/** The machine: its mark, a chip with how it answers, its name and address in monospace. */
@Composable
private fun LimaIdentity(model: MachineModel) {
    val colors = UniTheme.colors
    val identifier = UniTheme.type.identifierFamily
    val state = when {
        model.connected -> MachineState.CONNECTED
        model.checking -> MachineState.CHECKING
        else -> MachineState.SAVED
    }
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        LimaMachineGlyph(56.dp, fill = colors.surface, tint = if (model.connected) colors.accent else colors.muted)
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            LimaStateChip(state, fill = colors.surface)
            Text(
                model.machine.name, Modifier.padding(top = 6.dp), style = MaterialTheme.typography.headlineSmall, fontFamily = identifier,
                fontWeight = FontWeight.SemiBold, letterSpacing = (-0.02).em, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Text(
                model.machine.endpoint.displayAddress, Modifier.padding(top = 2.dp), style = MaterialTheme.typography.bodySmall,
                fontFamily = identifier, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * The bento of numbers for the picked tab, [scope]: the windows of one workspace, of all of them,
 * or the recent ones. While the machine answers: windows, working (lime when any) and waiting
 * (warning when any), and a tap on one filters the tab by it. Without an answer working and
 * waiting mean nothing, so the second tile counts the workspaces instead.
 */
@Composable
private fun LimaMetrics(model: MachineModel, scope: List<WindowItem>, onFilter: (WindowFilter) -> Unit) {
    val colors = UniTheme.colors
    // A window's state is null without an answer, so offline both counts are naturally zero.
    val windows = scope.size
    val workingCount = scope.count { it.activity == ActivityState.WORKING }
    val waitingCount = scope.count { it.activity == ActivityState.WAITING }
    val picks = model.connected && model.sections.isNotEmpty()
    Row(Modifier.fillMaxWidth().padding(top = 18.dp).height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(LimaGutter)) {
        LimaMetric(
            stringResource(R.string.windows), windows, Modifier.weight(1f).fillMaxHeight(),
            onClick = if (picks) ({ onFilter(WindowFilter.ALL) }) else null,
        )
        if (model.connected) {
            val working = workingCount > 0
            LimaMetric(
                stringResource(R.string.activity_state_working), workingCount, Modifier.weight(1f).fillMaxHeight(),
                fill = if (working) colors.accent else colors.surface,
                ink = if (working) colors.onAccent else colors.text,
                labelTone = if (working) colors.onAccent else colors.muted,
                onClick = if (picks) ({ onFilter(WindowFilter.WORKING) }) else null,
            )
            val waiting = waitingCount > 0
            LimaMetric(
                stringResource(R.string.activity_state_waiting), waitingCount, Modifier.weight(1f).fillMaxHeight(),
                ink = if (waiting) colors.warning else colors.text,
                labelTone = if (waiting) colors.warning else colors.muted,
                dot = if (waiting) colors.warning else null,
                onClick = if (picks) ({ onFilter(WindowFilter.WAITING) }) else null,
            )
        } else {
            LimaMetric(stringResource(R.string.design_workspaces), model.sections.size, Modifier.weight(1f).fillMaxHeight())
        }
    }
}

@Composable
private fun LimaMetric(
    label: String,
    value: Int,
    modifier: Modifier,
    fill: Color = UniTheme.colors.surface,
    ink: Color = UniTheme.colors.text,
    labelTone: Color = UniTheme.colors.muted,
    dot: Color? = null,
    onClick: (() -> Unit)? = null,
) {
    Column(
        modifier.heightIn(min = 80.dp).clip(UniTheme.shapes.card).background(fill)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (dot != null) Box(Modifier.padding(end = 6.dp).size(7.dp).background(dot, CircleShape))
            LimaEyebrow(label, color = labelTone)
        }
        Spacer(Modifier.weight(1f).heightIn(min = 8.dp))
        Text(
            value.toString(), color = ink, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold,
            fontSize = 30.sp, lineHeight = 32.sp, letterSpacing = (-0.03).em, maxLines = 1,
        )
    }
}

/** «Espacios», and a quiet warning when the host keeps favourites and order only on this phone. */
@Composable
private fun LimaSpacesLabel(model: MachineModel) {
    Column(Modifier.fillMaxWidth().padding(start = 4.dp, top = 22.dp)) {
        LimaEyebrow(stringResource(R.string.design_workspaces))
        if (model.hostKeepsOrder == false) Text(
            stringResource(R.string.box_local_only), Modifier.padding(top = 4.dp),
            style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.warning,
        )
    }
}

/**
 * The workspace tabs: a strip of bento tiles that scrolls sideways, «Recientes» first when the
 * host can say when each window was written to, then «Todos» and one per workspace in the
 * reader's order, each with its name, its window count large, its star and what its AIs do. The
 * picked tile is lime. A long press on a workspace opens its sheet (favourite, order, relaunch),
 * as its head does.
 */
@Composable
private fun LimaTabs(model: MachineModel, tab: WorkspaceTabSelection, state: LazyListState, onHold: (String) -> Unit) {
    val page = UniTheme.spacing.page
    val recent = model.canShowRecent
    val recentCount = remember(model) { model.recentWindows().size }
    // «Recientes», when shown, takes the first place and moves every other tile one along.
    val lead = if (recent) 1 else 0
    val index = when {
        tab.showsRecent -> 0
        tab.showsAll -> lead
        else -> lead + 1 + model.sections.indexOfFirst { it.workspace.id == tab.selected }
    }
    LaunchedEffect(tab.selected, index) {
        val info = state.layoutInfo
        val seen = info.visibleItemsInfo.firstOrNull { it.index == index }
        when {
            // Not laid out yet: the screen is opening, so jump instead of sliding in.
            info.visibleItemsInfo.isEmpty() -> state.scrollToItem(index)
            seen == null || seen.offset < info.viewportStartOffset || seen.offset + seen.size > info.viewportEndOffset ->
                state.animateScrollToItem(index)
        }
    }
    LazyRow(
        Modifier.padding(top = 10.dp).limaBleed(page).selectableGroup(),
        state = state,
        contentPadding = PaddingValues(horizontal = page),
        horizontalArrangement = Arrangement.spacedBy(LimaGutter),
    ) {
        if (recent) item(key = WorkspaceTabs.RECENT) {
            LimaTab(
                stringResource(R.string.design_tab_recent), recentCount, on = tab.showsRecent,
                onClick = { tab.select(WorkspaceTabs.RECENT) },
            )
        }
        item(key = WorkspaceTabs.ALL) {
            LimaTab(
                stringResource(R.string.lima_tab_all), model.sections.sumOf { it.windows.size }, on = tab.showsAll,
                onClick = { tab.select(WorkspaceTabs.ALL) },
            )
        }
        items(model.sections, key = { it.workspace.id }) { section ->
            val id = section.workspace.id
            LimaTab(
                section.workspace.name, section.windows.size, on = id == tab.selected, onClick = { tab.select(id) },
                identifier = true, pinned = section.pinned,
                activity = section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING },
                onLongClick = { onHold(id) },
            )
        }
    }
}

/**
 * One tab of the strip: a flat tile with the name on top and the window count large below, the
 * way the bento shows a number. On the lime of the picked tile the activity mark sits on a dot of
 * `onAccent`, since the waiting hand keeps its warning colour and would vanish on lime.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LimaTab(
    label: String,
    count: Int,
    on: Boolean,
    onClick: () -> Unit,
    identifier: Boolean = false,
    pinned: Boolean = false,
    activity: ActivityState? = null,
    onLongClick: (() -> Unit)? = null,
) {
    val colors = UniTheme.colors
    val ink = if (on) colors.onAccent else colors.text
    Column(
        Modifier.widthIn(min = 88.dp, max = 176.dp).clip(UniTheme.shapes.card).background(if (on) colors.accent else colors.surface)
            .combinedClickable(role = Role.Tab, onLongClick = onLongClick, onClick = onClick)
            .semantics { selected = on }
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                label, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelLarge, fontSize = 13.sp,
                fontFamily = if (identifier) UniTheme.type.identifierFamily else null, fontWeight = FontWeight.SemiBold,
                color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (pinned) {
                Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(12.dp), tint = if (on) colors.onAccent else colors.warning)
            }
        }
        Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                count.toString(), color = ink, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.Bold,
                fontSize = 24.sp, lineHeight = 26.sp, letterSpacing = (-0.03).em, maxLines = 1,
            )
            if (activity != null) {
                if (on) Box(Modifier.size(20.dp).background(colors.onAccent, CircleShape), contentAlignment = Alignment.Center) {
                    ActivityMark(activity, size = 13.dp)
                } else {
                    ActivityMark(activity, size = 15.dp)
                }
            }
        }
    }
}

/** All, working or waiting: Lima's segmented choice, the picked one filled with lime. */
@Composable
private fun LimaFilter(selected: WindowFilter, onSelect: (WindowFilter) -> Unit) {
    val colors = UniTheme.colors
    Row(
        Modifier.fillMaxWidth().padding(top = 10.dp).clip(UniTheme.shapes.button).background(colors.surface).padding(4.dp).selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        WindowFilter.entries.forEach { option ->
            val on = option == selected
            Box(
                Modifier.weight(1f).heightIn(min = 44.dp).clip(UniTheme.shapes.chip)
                    .then(if (on) Modifier.background(colors.accent) else Modifier)
                    .selectable(selected = on, role = Role.Tab) { onSelect(option) },
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
                    Modifier.padding(horizontal = 6.dp), style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    color = if (on) colors.onAccent else colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * A workspace's head: its name with favourite and activity marks, the window count and its kind,
 * and «+» for a new window. A tap or a long press opens its sheet (favourite, order, relaunch).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LimaSectionHead(section: WorkspaceSection, actions: MachineActions) {
    val colors = UniTheme.colors
    val workspace = section.workspace
    Row(
        Modifier.fillMaxWidth().padding(top = LimaGutter)
            .background(colors.surface, continuousTop(UniTheme.shapes.cardRadius))
            .padding(start = 6.dp, end = 6.dp, top = 6.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier.weight(1f).heightIn(min = 48.dp).clip(UniTheme.shapes.button)
                .combinedClickable(
                    onClick = { actions.onHoldWorkspace(workspace.id) },
                    onLongClick = { actions.onHoldWorkspace(workspace.id) },
                )
                .padding(start = 10.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.Center,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    workspace.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall, fontSize = 14.sp,
                    fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold, letterSpacing = 0.04.em,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (section.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
                section.activity?.takeIf { it == ActivityState.WORKING || it == ActivityState.WAITING }?.let { ActivityMark(it, size = 14.dp) }
            }
            Row(Modifier.padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    pluralStringResource(R.plurals.window_count, workspace.windows.size, workspace.windows.size),
                    style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1,
                )
                KindBadge(workspace)
            }
        }
        if (section.canCreateWindow) LimaSquareButton(
            Icons.Rounded.Add, stringResource(R.string.new_window), { actions.onCreateWindow(workspace.id) },
            fill = colors.surfaceRaised,
        )
    }
}

/**
 * The head of the block under a workspace's own tab. The tab already says its name and what its
 * AIs do, so only its kind and window count remain, with the star to make it a favourite and «+»
 * for a new window. A tap or a long press still opens its sheet.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LimaTabHead(section: WorkspaceSection, actions: MachineActions) {
    val colors = UniTheme.colors
    val workspace = section.workspace
    Row(
        Modifier.fillMaxWidth().padding(top = LimaGutter)
            .background(colors.surface, continuousTop(UniTheme.shapes.cardRadius))
            .padding(start = 6.dp, end = 6.dp, top = 6.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            Modifier.weight(1f).heightIn(min = 44.dp).clip(UniTheme.shapes.button)
                .combinedClickable(
                    onClick = { actions.onHoldWorkspace(workspace.id) },
                    onLongClick = { actions.onHoldWorkspace(workspace.id) },
                )
                .padding(start = 10.dp, end = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            KindBadge(workspace)
            Text(
                pluralStringResource(R.plurals.window_count, workspace.windows.size, workspace.windows.size),
                style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        LimaSquareButton(
            if (section.pinned) Icons.Rounded.Star else Icons.Rounded.StarBorder,
            stringResource(if (section.pinned) R.string.box_unpin else R.string.box_pin),
            { actions.onToggleWorkspacePin(workspace.id) },
            fill = colors.surfaceRaised,
            tint = if (section.pinned) colors.warning else colors.muted,
        )
        if (section.canCreateWindow) LimaSquareButton(
            Icons.Rounded.Add, stringResource(R.string.new_window), { actions.onCreateWindow(workspace.id) },
            fill = colors.surfaceRaised,
        )
    }
}

/**
 * One window inside its workspace's block: the AI's mark, the name, «Claude · Trabajando» with the
 * state in its colour, and a chevron, or «Responder» when the AI waits for the reader. Without a
 * connection [WindowItem.activity] is null and the row shows no state at all, on purpose.
 */
@Composable
private fun LimaWindowRow(section: WorkspaceSection, item: WindowItem, last: Boolean, actions: MachineActions) {
    val colors = UniTheme.colors
    val workspaceID = section.workspace.id
    val windowID = item.window.id
    Box(
        Modifier.fillMaxWidth()
            .background(colors.surface, if (last) limaFootShape(UniTheme.shapes.cardRadius) else RectangleShape)
            .padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = if (last) 6.dp else 2.dp),
    ) {
        LimaWindowPill(item, onOpen = { actions.onOpenWindow(workspaceID, windowID) }, onHold = { actions.onHoldWindow(workspaceID, windowID) }) {
            limaWindowLine(item)?.let { line ->
                Text(line, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/**
 * One window under «Recientes», a slice of the single block every recent window shares: the same
 * pill as inside a workspace, with a box naming its workspace and when the reader last wrote to it
 * under the name. No head says where these windows live, so the box does.
 */
@Composable
private fun LimaRecentRow(recent: RecentWindow, first: Boolean, last: Boolean, now: Long, actions: MachineActions) {
    val colors = UniTheme.colors
    val shapes = UniTheme.shapes
    val workspaceID = recent.workspace.id
    val windowID = recent.item.window.id
    val block = when {
        first && last -> shapes.card
        first -> continuousTop(shapes.cardRadius)
        last -> limaFootShape(shapes.cardRadius)
        else -> RectangleShape
    }
    Box(
        Modifier.fillMaxWidth().padding(top = if (first) LimaGutter else 0.dp)
            .background(colors.surface, block)
            .padding(start = 6.dp, end = 6.dp, top = if (first) 6.dp else 2.dp, bottom = if (last) 6.dp else 2.dp),
    ) {
        LimaWindowPill(recent.item, onOpen = { actions.onOpenWindow(workspaceID, windowID) }, onHold = { actions.onHoldWindow(workspaceID, windowID) }) {
            Row(Modifier.padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // The pill is already surfaceRaised, so the box keeps a hairline to stand apart from it.
                Text(
                    recent.workspace.name,
                    Modifier.widthIn(max = 168.dp).background(colors.surfaceRaised, shapes.chip).border(1.dp, colors.outline, shapes.chip)
                        .padding(horizontal = 6.dp, vertical = 1.dp),
                    style = MaterialTheme.typography.labelSmall, fontFamily = UniTheme.type.identifierFamily, fontWeight = FontWeight.SemiBold,
                    color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                elapsedText(recent.lastPromptAt, now)?.let { ago ->
                    Text(ago, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/**
 * A window as a raised pill: the AI's mark, the name with [under] beneath it, and a chevron, or
 * «Responder» when the AI waits for the reader. Without a connection [WindowItem.activity] is null
 * and the pill shows no state at all, on purpose.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LimaWindowPill(item: WindowItem, onOpen: () -> Unit, onHold: () -> Unit, under: @Composable () -> Unit) {
    val colors = UniTheme.colors
    val waiting = item.activity == ActivityState.WAITING
    Row(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(UniTheme.shapes.button).background(colors.surfaceRaised)
            .then(if (waiting) Modifier.background(colors.warning.copy(alpha = .10f)) else Modifier)
            .combinedClickable(onClick = onOpen, onLongClick = onHold)
            .padding(start = 14.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
            when (item.activity) {
                ActivityState.WORKING -> ActivityMark(ActivityState.WORKING, size = 18.dp)
                ActivityState.WAITING -> ActivityMark(ActivityState.WAITING, size = 18.dp)
                ActivityState.IDLE -> Box(Modifier.size(8.dp).background(colors.muted.copy(alpha = .6f), CircleShape))
                ActivityState.UNKNOWN, null -> {}
            }
        }
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(
                item.window.name, style = MaterialTheme.typography.bodyMedium, fontFamily = UniTheme.type.identifierFamily,
                fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            under()
        }
        if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
        if (waiting) {
            Text(
                stringResource(R.string.design_reply),
                Modifier.minimumInteractiveComponentSize().clip(UniTheme.shapes.chip).background(colors.warning)
                    .clickable(role = Role.Button, onClick = onOpen).padding(horizontal = 10.dp, vertical = 6.dp),
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = colors.onAccent, maxLines = 1,
            )
        } else {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(18.dp), tint = colors.muted)
        }
    }
}

/** [windowLine] with the state word in the state's colour: lime while working, warning when waiting. */
@Composable
private fun limaWindowLine(item: WindowItem): AnnotatedString? {
    val line = windowLine(item) ?: return null
    val state = activityText(item.activity)
    val tone = when (item.activity) {
        ActivityState.WORKING -> UniTheme.colors.accent
        ActivityState.WAITING -> UniTheme.colors.warning
        else -> null
    }
    if (state == null || tone == null || !line.endsWith(state)) return AnnotatedString(line)
    return buildAnnotatedString {
        append(line.dropLast(state.length))
        withStyle(SpanStyle(color = tone, fontWeight = FontWeight.Medium)) { append(state) }
    }
}

/** A block with no windows to list, because it has none or the filter hides them: its foot says which. */
@Composable
private fun LimaEmptySection(text: String) {
    Box(
        Modifier.fillMaxWidth().background(UniTheme.colors.surface, limaFootShape(UniTheme.shapes.cardRadius))
            .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 16.dp),
    ) {
        Text(text, style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
    }
}

/** A message in a block of its own: no workspaces, or nothing in the state the filter asks for. */
@Composable
private fun LimaNote(text: String) {
    Box(Modifier.fillMaxWidth().padding(top = LimaGutter).clip(UniTheme.shapes.card).background(UniTheme.colors.surface).padding(18.dp)) {
        Text(text, style = MaterialTheme.typography.bodyMedium, color = UniTheme.colors.muted)
    }
}

/**
 * «Nuevo espacio de trabajo», floating bottom right. It sits on a ring of the page colour instead
 * of a shadow, so the rows scrolling under it stay apart from it in a flat design.
 */
@Composable
private fun LimaNewWorkspaceButton(onClick: () -> Unit, modifier: Modifier) {
    val colors = UniTheme.colors
    Box(modifier.background(colors.background, ContinuousRoundedShape(UniTheme.shapes.buttonRadius + 6.dp)).padding(6.dp)) {
        Row(
            Modifier.heightIn(min = 52.dp).clip(UniTheme.shapes.button).background(colors.accent)
                .clickable(role = Role.Button, onClick = onClick).padding(start = 16.dp, end = 18.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Rounded.Add, null, Modifier.size(20.dp), tint = colors.onAccent)
            Text(
                stringResource(R.string.new_workspace), style = MaterialTheme.typography.titleSmall, fontSize = 15.sp,
                fontFamily = UniTheme.type.headlineFamily, fontWeight = FontWeight.SemiBold, color = colors.onAccent, maxLines = 1,
            )
        }
    }
}

/** Only the bottom corners rounded: the foot of a workspace's block. */
private fun limaFootShape(radius: Dp) =
    ContinuousRoundedShape(topStart = 0.dp, topEnd = 0.dp, bottomEnd = radius, bottomStart = radius)

/**
 * Widens a row by [margin] on each side, past the list's side padding to the screen's edges, so a
 * strip that scrolls sideways runs under them instead of being cut at the page margin.
 */
private fun Modifier.limaBleed(margin: Dp) = layout { measurable, constraints ->
    if (!constraints.hasBoundedWidth) {
        val placeable = measurable.measure(constraints)
        return@layout layout(placeable.width, placeable.height) { placeable.place(0, 0) }
    }
    val extra = margin.roundToPx() * 2
    val width = constraints.maxWidth + extra
    val placeable = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
    layout(constraints.maxWidth, placeable.height) { placeable.place(-extra / 2, 0) }
}
