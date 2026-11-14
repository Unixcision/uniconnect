package com.unixcision.uniconnect.android.ui.design.nieve

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
import com.unixcision.uniconnect.android.ui.design.MachineModel
import com.unixcision.uniconnect.android.ui.design.WorkspaceTabs
import org.junit.Assert.assertEquals
import org.junit.Test

/** A tap on a number of the machine's summary opens «Todos» on exactly the windows it counts. */
class NieveSummaryPickTest {
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)

    private fun window(id: String, state: ActivityState?) =
        RemoteWindow(id, id.uppercase(), "terminal", activity = state?.let { RemoteActivity(it, agent = "claude") })

    private val snapshot = MachineSnapshot("Mac", listOf(
        RemoteWorkspace("p", "PROYECTOS", isSSH = false, windows = listOf(
            window("a", ActivityState.WORKING), window("b", ActivityState.IDLE), window("c", null),
        )),
        RemoteWorkspace("n", "NOTBETTING", isSSH = true, windows = listOf(
            window("d", ActivityState.WAITING), window("e", ActivityState.WORKING), window("f", ActivityState.WORKING),
        )),
        RemoteWorkspace("g", "GESTION", isSSH = false, windows = listOf(window("h", ActivityState.IDLE))),
    ))

    private fun shown(model: MachineModel, kind: NieveStatKind): List<String> =
        model.visible(WorkspaceTabs.ALL, kind.filter).flatMap { section -> section.windows.map { it.window.id } }

    @Test
    fun eachNumberOpensTheWindowsItCounts() {
        val model = MachineModel.of(mac, MachinesViewModel.Connection(connected = true, snapshot = snapshot), BoxOverrides(), null, null, null)
        val summary = model.summary
        assertEquals(7, summary.windows)
        assertEquals(summary.windows, shown(model, NieveStatKind.WINDOWS).size)
        assertEquals(summary.working, shown(model, NieveStatKind.WORKING).size)
        assertEquals(setOf("a", "e", "f"), shown(model, NieveStatKind.WORKING).toSet())
        assertEquals(summary.waiting, shown(model, NieveStatKind.WAITING).size)
        assertEquals(listOf("d"), shown(model, NieveStatKind.WAITING))
    }

    @Test
    fun withoutAnAnswerTheNumbersOpenEverything() {
        // Offline the block counts workspaces and windows, and both open «Todos» unfiltered.
        assertEquals(WindowFilter.ALL, NieveStatKind.WORKSPACES.filter)
        assertEquals(WindowFilter.ALL, NieveStatKind.WINDOWS.filter)
        val model = MachineModel.of(mac, MachinesViewModel.Connection(checking = true, snapshot = snapshot), BoxOverrides(), null, null, null)
        assertEquals(model.summary.windows, shown(model, NieveStatKind.WINDOWS).size)
    }
}
