package com.unixcision.uniconnect.android.ui.design

import com.unixcision.uniconnect.android.domain.ActivityState
import com.unixcision.uniconnect.android.domain.BoxOverrides
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.MachineSnapshot
import com.unixcision.uniconnect.android.domain.RemoteActivity
import com.unixcision.uniconnect.android.domain.RemoteWindow
import com.unixcision.uniconnect.android.domain.RemoteWorkspace
import com.unixcision.uniconnect.android.domain.WindowFilter
import com.unixcision.uniconnect.android.ui.MachinesViewModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The machine screen shows every workspace at once, in the reader's order, and no stale activity. */
class MachineModelTest {
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)

    private fun window(id: String, state: ActivityState?, agent: String? = "claude") =
        RemoteWindow(id, id.uppercase(), "terminal", activity = state?.let { RemoteActivity(it, agent = agent) })

    private val snapshot = MachineSnapshot("Mac", listOf(
        RemoteWorkspace("p", "PROYECTOS", isSSH = false, windows = listOf(window("claude", ActivityState.WORKING), window("codex", ActivityState.IDLE, "codex"))),
        RemoteWorkspace("n", "NOTBETTING", isSSH = null, windows = listOf(window("app1", ActivityState.WORKING), window("app2", ActivityState.WAITING))),
    ))

    @Test
    fun aConnectedMachineListsEveryWorkspaceWithFavouritesFirstAndTheirActivity() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = snapshot),
            BoxOverrides(pinnedWorkspaces = setOf("n"), pinnedWindows = setOf("app2")), hostKeepsOrder = false, noticeLink = null, focusWorkspaceID = "p")
        assertEquals(listOf("n", "p"), model.sections.map { it.workspace.id })
        val notbetting = model.sections.first()
        assertTrue(notbetting.pinned)
        assertEquals(listOf("app2", "app1"), notbetting.windows.map { it.window.id })
        assertEquals(ActivityState.WAITING, notbetting.activity)
        // The host never said what kind of box it is, so no window can be added there.
        assertFalse(notbetting.canCreateWindow)
        assertTrue(model.sections.last().canCreateWindow)
        assertEquals("Codex", model.sections.last().windows.last().agent)
        assertEquals(2, model.summary.working)
        assertEquals(1, model.summary.waiting)
        assertTrue(model.canCreateWorkspace)
        assertEquals("p", model.focusWorkspaceID)
    }

    @Test
    fun aMachineNotAnsweringShowsItsLastListWithoutAnyActivity() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(checking = true, snapshot = snapshot), BoxOverrides(), null, null, null)
        assertTrue(model.hasSnapshot)
        assertFalse(model.connected)
        assertTrue(model.sections.all { section -> section.activity == null && !section.canCreateWindow && section.windows.all { it.activity == null } })
        assertEquals(0, model.summary.working)
        assertFalse(model.canCreateWorkspace)
    }

    @Test
    fun aFilterKeepsOnlyItsWindowsAndDropsTheWorkspacesLeftEmpty() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = snapshot), BoxOverrides(), null, null, null)
        val waiting = model.filtered(WindowFilter.WAITING)
        assertEquals(listOf("n"), waiting.map { it.workspace.id })
        assertEquals(listOf("app2"), waiting.single().windows.map { it.window.id })
        assertEquals(listOf("p", "n"), model.filtered(WindowFilter.WORKING).map { it.workspace.id })
        assertEquals(model.sections, model.filtered(WindowFilter.ALL))
    }

    @Test
    fun aMachineNeverReadHasNothingToList() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(error = 1), BoxOverrides(), null, null, null)
        assertFalse(model.hasSnapshot)
        assertTrue(model.sections.isEmpty())
        assertEquals(1, model.error)
        assertNull(model.noticeLink)
    }
}
