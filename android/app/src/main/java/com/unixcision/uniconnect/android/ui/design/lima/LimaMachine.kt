package com.unixcision.uniconnect.android.ui.design.lima

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
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
import com.unixcision.uniconnect.android.ui.design.WindowItem
import com.unixcision.uniconnect.android.ui.design.WorkspaceSection
import com.unixcision.uniconnect.android.ui.design.activityText
import com.unixcision.uniconnect.android.ui.design.windowLine
import com.unixcision.uniconnect.android.ui.theme.ContinuousRoundedShape
import com.unixcision.uniconnect.android.ui.theme.UniTheme
import com.unixcision.uniconnect.android.ui.theme.continuousTop

/**
 * Lima's machine screen: the machine with its state chip, a bento of three numbers (windows,
 * working, waiting) that double as the filter, and every workspace as one block with its windows
 * inside. A window that waits for the reader is tinted and offers «Responder».
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
    val entries = remember(model, shown) { limaEntries(model, shown) }
    val list = rememberLazyListState()
    LaunchedEffect(model.focusWorkspaceID, model.sections.isNotEmpty()) {
        val id = model.focusWorkspaceID ?: return@LaunchedEffect
        // A notice may name a workspace the filter hides: show everything rather than nothing.
        if (model.filtered(shown).none { it.workspace.id == id }) filter = WindowFilter.ALL
        val target = if (model.connected) filter else WindowFilter.ALL
        val index = limaEntries(model, target).indexOfFirst { it is LimaEntry.Head && it.section.workspace.id == id }
        if (index >= 0) list.scrollToItem(index)
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
                        LimaEntry.Metrics -> LimaMetrics(model) { filter = it }
                        LimaEntry.Spaces -> LimaSpacesLabel(model)
                        LimaEntry.Filter -> LimaFilter(shown) { filter = it }
                        LimaEntry.NoWorkspaces -> LimaNote(stringResource(R.string.no_workspaces))
                        LimaEntry.NoMatches -> LimaNote(stringResource(R.string.design_no_filtered_windows))
                        is LimaEntry.Head -> LimaSectionHead(entry.section, actions)
                        is LimaEntry.Window -> LimaWindowRow(entry.section, entry.item, entry.last, actions)
                        is LimaEntry.Empty -> LimaEmptySection()
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
    data object Filter : LimaEntry { override val key = "filter" }
    data object NoWorkspaces : LimaEntry { override val key = "no-workspaces" }
    data object NoMatches : LimaEntry { override val key = "no-matches" }
    data object Notices : LimaEntry { override val key = "notices" }
    data class Head(val section: WorkspaceSection) : LimaEntry {
        override val key get() = "ws:${section.workspace.id}"
    }
    data class Window(val section: WorkspaceSection, val item: WindowItem, val last: Boolean) : LimaEntry {
        override val key get() = "win:${section.workspace.id}:${item.window.id}"
    }
    data class Empty(val section: WorkspaceSection) : LimaEntry {
        override val key get() = "empty:${section.workspace.id}"
    }
}

/** The list in display order; pure, so the focus effect can find a head's index without the UI. */
private fun limaEntries(model: MachineModel, filter: WindowFilter): List<LimaEntry> = buildList {
    add(LimaEntry.Identity)
    if (!model.hasSnapshot) {
        add(LimaEntry.Offline)
    } else {
        if (!model.connected) add(LimaEntry.Stale)
        add(LimaEntry.Metrics)
        add(LimaEntry.Spaces)
        if (model.sections.isEmpty()) {
            add(LimaEntry.NoWorkspaces)
        } else {
            if (model.connected) add(LimaEntry.Filter)
            val sections = model.filtered(filter)
            if (sections.isEmpty()) add(LimaEntry.NoMatches)
            sections.forEach { section ->
                add(LimaEntry.Head(section))
                if (section.windows.isEmpty()) add(LimaEntry.Empty(section))
                section.windows.forEachIndexed { index, item -> add(LimaEntry.Window(section, item, last = index == section.windows.lastIndex)) }
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
 * The bento of numbers. While the machine answers: windows, working (lime when any) and waiting
 * (warning when any), and a tap on one filters the list by it. Without an answer working and
 * waiting mean nothing, so the second tile counts the workspaces instead.
 */
@Composable
private fun LimaMetrics(model: MachineModel, onFilter: (WindowFilter) -> Unit) {
    val colors = UniTheme.colors
    val summary = model.summary
    val picks = model.connected && model.sections.isNotEmpty()
    Row(Modifier.fillMaxWidth().padding(top = 18.dp).height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(LimaGutter)) {
        LimaMetric(
            stringResource(R.string.windows), summary.windows, Modifier.weight(1f).fillMaxHeight(),
            onClick = if (picks) ({ onFilter(WindowFilter.ALL) }) else null,
        )
        if (model.connected) {
            val working = summary.working > 0
            LimaMetric(
                stringResource(R.string.activity_state_working), summary.working, Modifier.weight(1f).fillMaxHeight(),
                fill = if (working) colors.accent else colors.surface,
                ink = if (working) colors.onAccent else colors.text,
                labelTone = if (working) colors.onAccent else colors.muted,
                onClick = if (picks) ({ onFilter(WindowFilter.WORKING) }) else null,
            )
            val waiting = summary.waiting > 0
            LimaMetric(
                stringResource(R.string.activity_state_waiting), summary.waiting, Modifier.weight(1f).fillMaxHeight(),
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
 * One window inside its workspace's block: the AI's mark, the name, «Claude · Trabajando» with the
 * state in its colour, and a chevron, or «Responder» when the AI waits for the reader. Without a
 * connection [WindowItem.activity] is null and the row shows no state at all, on purpose.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LimaWindowRow(section: WorkspaceSection, item: WindowItem, last: Boolean, actions: MachineActions) {
    val colors = UniTheme.colors
    val workspaceID = section.workspace.id
    val windowID = item.window.id
    val waiting = item.activity == ActivityState.WAITING
    val open = { actions.onOpenWindow(workspaceID, windowID) }
    Box(
        Modifier.fillMaxWidth()
            .background(colors.surface, if (last) limaFootShape(UniTheme.shapes.cardRadius) else RectangleShape)
            .padding(start = 6.dp, end = 6.dp, top = 2.dp, bottom = if (last) 6.dp else 2.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(UniTheme.shapes.button).background(colors.surfaceRaised)
                .then(if (waiting) Modifier.background(colors.warning.copy(alpha = .10f)) else Modifier)
                .combinedClickable(onClick = open, onLongClick = { actions.onHoldWindow(workspaceID, windowID) })
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
                limaWindowLine(item)?.let { line ->
                    Text(line, style = MaterialTheme.typography.bodySmall, color = colors.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (item.pinned) Icon(Icons.Rounded.Star, stringResource(R.string.box_pinned), Modifier.size(14.dp), tint = colors.warning)
            if (waiting) {
                Text(
                    stringResource(R.string.design_reply),
                    Modifier.minimumInteractiveComponentSize().clip(UniTheme.shapes.chip).background(colors.warning)
                        .clickable(role = Role.Button, onClick = open).padding(horizontal = 10.dp, vertical = 6.dp),
                    style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = colors.onAccent, maxLines = 1,
                )
            } else {
                Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, null, Modifier.size(18.dp), tint = colors.muted)
            }
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

/** A workspace with no windows: the foot of its block says so. */
@Composable
private fun LimaEmptySection() {
    Box(
        Modifier.fillMaxWidth().background(UniTheme.colors.surface, limaFootShape(UniTheme.shapes.cardRadius))
            .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 16.dp),
    ) {
        Text(stringResource(R.string.no_windows), style = MaterialTheme.typography.bodySmall, color = UniTheme.colors.muted)
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
