package com.unixcision.uniconnect.android.ui.design

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue

/**
 * The workspace tabs of a machine screen. A machine with seventy windows listed in one column
 * was an endless scroll: the screen shows one workspace at a time, with a tab per workspace and
 * one for all of them.
 */
object WorkspaceTabs {
    /** The tab that shows every workspace. */
    const val ALL = "*"
}

/** The selected tab of a machine screen and how to change it. */
class WorkspaceTabSelection(
    /** A workspace id, or [WorkspaceTabs.ALL]. */
    val selected: String,
    val select: (String) -> Unit,
) {
    val showsAll: Boolean get() = selected == WorkspaceTabs.ALL
}

/**
 * Remembers the tab across recompositions and rotations, per machine. A tab whose workspace
 * went away falls back to [MachineModel.defaultTab] without writing state from the body, and a
 * notice or a closed window that points at a workspace selects it.
 */
@Composable
fun rememberWorkspaceTab(model: MachineModel): WorkspaceTabSelection {
    var stored by rememberSaveable(model.machine.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(model.machine.id, model.focusWorkspaceID) {
        val focus = model.focusWorkspaceID
        if (focus != null && model.sections.any { it.workspace.id == focus }) stored = focus
    }
    return WorkspaceTabSelection(model.effectiveTab(stored)) { stored = it }
}
