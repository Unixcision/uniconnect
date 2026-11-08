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

    @Test
    fun theScreenOpensOnTheFocusedWorkspaceElseWhereAnAIWaitsElseTheFirst() {
        val connected = MachinesViewModel.Connection(connected = true, snapshot = snapshot)
        assertEquals("p", MachineModel.of(mac, connected, BoxOverrides(), null, null, focusWorkspaceID = "p").defaultTab())
        // NOTBETTING has APP 2 waiting, so it wins over PROYECTOS although it comes second.
        assertEquals("n", MachineModel.of(mac, connected, BoxOverrides(), null, null, null).defaultTab())
        val quiet = MachineSnapshot("Mac", listOf(RemoteWorkspace("a", "A", false, emptyList()), RemoteWorkspace("b", "B", false, emptyList())))
        assertEquals("a", MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = quiet), BoxOverrides(), null, null, null).defaultTab())
        assertEquals(WorkspaceTabs.ALL, MachineModel.of(mac, MachinesViewModel.Connection(), BoxOverrides(), null, null, null).defaultTab())
    }

    @Test
    fun aTabShowsOneWorkspaceAndAVanishedOneFallsBackToTheDefault() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = snapshot), BoxOverrides(), null, null, null)
        assertEquals(listOf("p"), model.visible("p", WindowFilter.ALL).map { it.workspace.id })
        assertEquals(listOf("p", "n"), model.visible(WorkspaceTabs.ALL, WindowFilter.ALL).map { it.workspace.id })
        // The filter works inside the tab: PROYECTOS has nobody waiting.
        assertTrue(model.visible("p", WindowFilter.WAITING).isEmpty())
        assertEquals("p", model.effectiveTab("p"))
        assertEquals(WorkspaceTabs.ALL, model.effectiveTab(WorkspaceTabs.ALL))
        assertEquals("n", model.effectiveTab("gone"))
        assertEquals("n", model.effectiveTab(null))
    }

    private fun prompted(id: String, state: ActivityState?, at: Long?) =
        RemoteWindow(id, id.uppercase(), "terminal", activity = state?.let { RemoteActivity(it, agent = "claude") }, lastPromptAt = at)

    private val prompts = MachineSnapshot("Mac", listOf(
        RemoteWorkspace("p", "PROYECTOS", isSSH = false, windows = listOf(prompted("claude", ActivityState.WORKING, 1_800_000_100), prompted("logs", null, null))),
        RemoteWorkspace("n", "NOTBETTING", isSSH = false, windows = listOf(prompted("app1", ActivityState.WAITING, 1_800_000_300), prompted("app2", ActivityState.IDLE, 1_800_000_200))),
    ), capabilities = setOf(MachineSnapshot.RECENT_PROMPTS))

    @Test
    fun recentListsTheWindowsOfEveryWorkspaceByTheirLastPromptMostRecentFirst() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = prompts), BoxOverrides(), null, null, null, nowEpochSeconds = 1_800_000_400)
        val recent = model.recentWindows()
        assertEquals(listOf("app1", "app2", "claude"), recent.map { it.item.window.id })
        // Each one says where it lives and when it was written to; a window never prompted is not there.
        assertEquals(listOf("n", "n", "p"), recent.map { it.workspace.id })
        assertEquals(listOf(1_800_000_300L, 1_800_000_200L, 1_800_000_100L), recent.map { it.lastPromptAt })
        assertEquals(1_800_000_400L, model.nowEpochSeconds)
        assertTrue(model.canShowRecent)
    }

    @Test
    fun theFilterAppliesUnderRecentToo() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = prompts), BoxOverrides(), null, null, null)
        assertEquals(listOf("app1"), model.recentWindows(WindowFilter.WAITING).map { it.item.window.id })
        assertEquals(listOf("claude"), model.recentWindows(WindowFilter.WORKING).map { it.item.window.id })
    }

    @Test
    fun recentIsATabOnlyWithTheCapabilityAndSomethingToShowAndNeverTheDefault() {
        val connected = MachinesViewModel.Connection(connected = true, snapshot = prompts)
        val model = MachineModel.of(mac, connected, BoxOverrides(), null, null, null)
        assertEquals(WorkspaceTabs.RECENT, model.effectiveTab(WorkspaceTabs.RECENT))
        // The screen still opens where an AI waits.
        assertEquals("n", model.defaultTab())
        assertTrue(model.visible(WorkspaceTabs.RECENT, WindowFilter.ALL).isEmpty())
        // Without the capability a missing time means «not sent», so the tab is not offered.
        val old = MachineModel.of(mac, connected.copy(snapshot = prompts.copy(capabilities = emptySet())), BoxOverrides(), null, null, null)
        assertFalse(old.canShowRecent)
        assertEquals("n", old.effectiveTab(WorkspaceTabs.RECENT))
        // With it but nothing ever written, there is nothing to list either.
        val silent = prompts.copy(workspaces = prompts.workspaces.map { box -> box.copy(windows = box.windows.map { it.copy(lastPromptAt = null) }) })
        assertFalse(MachineModel.of(mac, connected.copy(snapshot = silent), BoxOverrides(), null, null, null).canShowRecent)
    }
}
