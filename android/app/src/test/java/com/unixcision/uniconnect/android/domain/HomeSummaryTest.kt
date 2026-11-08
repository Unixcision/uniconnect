package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** The home counts machines, windows and the AIs working or waiting, the way the windows say. */
class HomeSummaryTest {
    private fun window(id: String, state: String?) = RemoteWindow(id, id, "terminal", activity = state?.let { RemoteActivity(ActivityState.parse(it)) })

    @Test
    fun aMachineCountsItsWindowsAndWhatTheirAIsAreDoing() {
        val snapshot = MachineSnapshot(
            "Mac", listOf(
                RemoteWorkspace("w1", "PROYECTOS", isSSH = false, windows = listOf(window("a", "working"), window("b", "waiting"), window("c", "idle"))),
                RemoteWorkspace("w2", "NOTBETTING", isSSH = false, windows = listOf(window("d", "working"), window("e", null))),
            ),
        )
        assertEquals(HomeSummary(machines = 1, connected = 1, windows = 5, working = 2, waiting = 1), HomeSummary.of(connected = true, snapshot))
        assertEquals(HomeSummary(machines = 1, connected = 0, windows = 0, working = 0, waiting = 0), HomeSummary.of(connected = false, null))
        // A machine that stopped answering keeps its windows but none of its stale AI states.
        assertEquals(HomeSummary(machines = 1, connected = 0, windows = 5, working = 0, waiting = 0), HomeSummary.of(connected = false, snapshot))
    }

    @Test
    fun theHomeAddsEveryMachineUp() {
        val total = HomeSummary.total(listOf(HomeSummary(1, 1, 27, 3, 1), HomeSummary(1, 0, 67, 5, 2)))
        assertEquals(HomeSummary(machines = 2, connected = 1, windows = 94, working = 8, waiting = 3), total)
    }

    @Test
    fun theGreetingFollowsTheHour() {
        assertEquals(Greeting.NIGHT, Greeting.at(5))
        assertEquals(Greeting.MORNING, Greeting.at(6))
        assertEquals(Greeting.MORNING, Greeting.at(13))
        assertEquals(Greeting.AFTERNOON, Greeting.at(14))
        assertEquals(Greeting.AFTERNOON, Greeting.at(20))
        assertEquals(Greeting.NIGHT, Greeting.at(21))
    }
}
