package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Immutable
import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.AgentLabel
import com.unixcision.uniconnect.android.domain.BoxArrangement
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.HomeSummary
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.NotificationLinkState
import com.unixcision.uniconnect.android.domain.RemoteWindow
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import com.unixcision.uniconnect.android.domain.WindowFilter
import com.unixcision.uniconnect.android.ui.MachinesViewModel

/**
 * One machine as every design shows it: all its workspaces at once, each with its windows, in
 * the order the reader chose (favourites first).
 *
 * Activity is only shown while the machine answers. A list read before connecting is a picture
 * of the past: drawing its spinners made every window look busy until the connection came up.
 */
@Immutable
data class MachineModel(
    val machine: Machine,
    val connected: Boolean,
    val checking: Boolean,
    /** Why the last attempt failed, as a string resource; null when it did not. */
    val error: Int?,
    /** Whether a workspace list was ever read; without one there is nothing to show but how to connect. */
    val hasSnapshot: Boolean,
    val summary: HomeSummary,
    val sections: List<WorkspaceSection>,
    /** The workspace a notice pointed at, to bring into view once; null otherwise. */
    val focusWorkspaceID: String?,
    val noticeLink: NotificationLinkState?,
    /** False when the host does not keep favourites and order: they then live only on this phone. */
    val hostKeepsOrder: Boolean?,
) {
    /** Whether a new workspace can be asked for now. */
    val canCreateWorkspace: Boolean get() = connected

    /**
     * The tab the machine screen opens on: the workspace a notice or a closed window pointed at,
     * else the first one where an AI waits, else the first one. [WorkspaceTabs.ALL] only when
     * there is no workspace to pick.
     */
    fun defaultTab(): String =
        focusWorkspaceID?.takeIf { id -> sections.any { it.workspace.id == id } }
            ?: sections.firstOrNull { it.activity == ActivityState.WAITING }?.workspace?.id
            ?: sections.firstOrNull()?.workspace?.id
            ?: WorkspaceTabs.ALL

    /** [tab] if it still names a workspace (or is [WorkspaceTabs.ALL]); otherwise [defaultTab]. */
    fun effectiveTab(tab: String?): String =
        tab?.takeIf { it == WorkspaceTabs.ALL || sections.any { section -> section.workspace.id == it } } ?: defaultTab()

    /** What the screen lists under [tab] with [filter]: one workspace, or all of them. */
    fun visible(tab: String, filter: WindowFilter): List<WorkspaceSection> {
        val shown = filtered(filter)
        return if (tab == WorkspaceTabs.ALL) shown else shown.filter { it.workspace.id == tab }
    }

    /** The sections with only the windows [filter] accepts; with a filter, empty sections go. */
    fun filtered(filter: WindowFilter): List<WorkspaceSection> =
        if (filter == WindowFilter.ALL) sections
        else sections.map { section -> section.copy(windows = section.windows.filter { filter.accepts(it.activity) }) }.filter { it.windows.isNotEmpty() }

    companion object {
        /** Builds the model from the view model's connection and the phone's own favourites. */
        fun of(
            machine: Machine,
            connection: MachinesViewModel.Connection,
            overrides: BoxOverrides,
            hostKeepsOrder: Boolean?,
            noticeLink: NotificationLinkState?,
            focusWorkspaceID: String?,
        ): MachineModel {
            val snapshot = connection.snapshot
            val live = connection.connected
            val sections = snapshot?.let { BoxArrangement.workspaces(it, overrides) }.orEmpty().map { workspace ->
                val windows = BoxArrangement.windows(workspace, overrides).map { window ->
                    WindowItem(
                        window = window,
                        pinned = window.isPinned || window.id in overrides.pinnedWindows,
                        activity = window.activity?.state?.takeIf { live },
                        agent = AgentLabel.of(window.activity?.agent),
                    )
                }
                WorkspaceSection(
                    workspace = workspace,
                    pinned = workspace.isPinned || workspace.id in overrides.pinnedWorkspaces,
                    windows = windows,
                    activity = workspace.activity.takeIf { live },
                    canCreateWindow = live && workspace.isSSH != null,
                )
            }
            return MachineModel(
                machine = machine, connected = live, checking = connection.checking, error = connection.error,
                hasSnapshot = snapshot != null, summary = HomeSummary.of(live, snapshot), sections = sections,
                focusWorkspaceID = focusWorkspaceID, noticeLink = noticeLink, hostKeepsOrder = hostKeepsOrder,
            )
        }
    }
}

/** One workspace and its windows, as shown on the machine screen. */
@Immutable
data class WorkspaceSection(
    val workspace: RemoteWorkspace,
    val pinned: Boolean,
    val windows: List<WindowItem>,
    /** The most pressing state of its windows while connected; null when it cannot be known. */
    val activity: ActivityState?,
    /** Whether a window can be added here now (connected, and the host said what kind of box it is). */
    val canCreateWindow: Boolean,
)

/** One window, as shown on the machine screen. */
@Immutable
data class WindowItem(
    val window: RemoteWindow,
    val pinned: Boolean,
    /** What its AI is doing while the machine answers; null when not connected or not reported. */
    val activity: ActivityState?,
    /** The AI's name ("Claude", "Codex"), or null for a plain terminal. */
    val agent: String?,
)

/** What the machine screen can do; every design wires the same actions. */
@Immutable
class MachineActions(
    val onBack: () -> Unit,
    val onConnect: () -> Unit,
    val onEnableNotices: () -> Unit,
    val onDisableNotices: () -> Unit,
    val onCreateWorkspace: () -> Unit,
    val onCreateWindow: (workspaceID: String) -> Unit,
    val onOpenWindow: (workspaceID: String, windowID: String) -> Unit,
    val onToggleWorkspacePin: (workspaceID: String) -> Unit,
    /** Long press: the sheet with favourite, order and relaunch for a workspace. */
    val onHoldWorkspace: (workspaceID: String) -> Unit,
    /** Long press: the same sheet for one window. */
    val onHoldWindow: (workspaceID: String, windowID: String) -> Unit,
)
