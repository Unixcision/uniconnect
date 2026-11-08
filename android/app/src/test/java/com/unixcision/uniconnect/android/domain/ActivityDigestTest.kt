package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** The home's digest says who waits, who works and what changed lately, from the hosts' own `since`. */
class ActivityDigestTest {
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)
    private val linux = Machine("lin", "MINIPC Linux", MachineEndpoint.parse("100.64.0.2", "58465")!!)
    private val now = 1_800_000_000L

    private fun window(id: String, state: ActivityState, agent: String? = "claude", since: Long? = null) =
        RemoteWindow(id, id.uppercase(), "terminal", activity = RemoteActivity(state, agent = agent, sinceEpochSeconds = since))

    @Test
    fun waitingAndWorkingWindowsComeNewestFirstWithTheRouteThatOpensThem() {
        val snapshots = mapOf(
            "mac" to MachineSnapshot("Mac", listOf(RemoteWorkspace("w1", "NOTBETTING", false, listOf(
                window("app1", ActivityState.WORKING, since = now - 600),
                window("app2", ActivityState.WAITING, since = now - 120),
            )))),
            "lin" to MachineSnapshot("Linux", listOf(RemoteWorkspace("w9", "IBERIAVO", true, listOf(
                window("codex", ActivityState.WORKING, agent = "codex", since = now - 60),
                window("old", ActivityState.WAITING, since = now - 7200),
            )))),
        )
        val digest = ActivityDigest.of(listOf(mac, linux), snapshots, setOf("mac", "lin"), now)
        assertEquals(listOf("app2", "old"), digest.waiting.map { it.route.windowID })
        assertEquals(NoticeRoute("mac", "w1", "app2"), digest.waiting.first().route)
        assertEquals("NOTBETTING", digest.waiting.first().workspaceName)
        assertEquals("MacBook de Daniel", digest.waiting.first().machineName)
        assertEquals(listOf("codex", "app1"), digest.working.map { it.route.windowID })
    }

    @Test
    fun recentKeepsTheLastDayOfAIChangesAndLeavesQuietShellsOut() {
        val snapshots = mapOf(
            "mac" to MachineSnapshot("Mac", listOf(RemoteWorkspace("w1", "PROYECTOS", false, listOf(
                window("idleAI", ActivityState.IDLE, agent = "codex", since = now - 840),
                window("shell", ActivityState.IDLE, agent = null, since = now - 30),
                window("ancient", ActivityState.IDLE, since = now - 3 * 86_400),
                window("noSince", ActivityState.WORKING, since = null),
                window("unknown", ActivityState.UNKNOWN, since = now - 10),
                window("waiting", ActivityState.WAITING, since = now - 120),
            )))),
        )
        val digest = ActivityDigest.of(listOf(mac), snapshots, setOf("mac"), now)
        assertEquals(listOf("waiting", "idleAI"), digest.recent.map { it.route.windowID })
        // A window with no since still counts as working; it just has no place on the timeline.
        assertEquals(listOf("noSince"), digest.working.map { it.route.windowID })
    }

    @Test
    fun recentStopsAtItsLimitAndAMachineWithoutAListAddsNothing() {
        val windows = (1..10).map { window("w$it", ActivityState.WORKING, since = now - it * 60L) }
        val digest = ActivityDigest.of(listOf(mac, linux), mapOf("mac" to MachineSnapshot("Mac", listOf(RemoteWorkspace("w", "W", false, windows))), "lin" to null), setOf("mac", "lin"), now)
        assertEquals(ActivityDigest.RECENT_LIMIT, digest.recent.size)
        assertEquals("w1", digest.recent.first().route.windowID)
        assertEquals(10, digest.working.size)
    }

    @Test
    fun aMachineThatDoesNotAnswerAddsNothingFromItsLastList() {
        val snapshots = mapOf("mac" to MachineSnapshot("Mac", listOf(RemoteWorkspace("w1", "APP", false, listOf(
            window("app2", ActivityState.WAITING, since = now - 60), window("app1", ActivityState.WORKING, since = now - 60),
        )))))
        assertEquals(ActivityDigest.empty, ActivityDigest.of(listOf(mac), snapshots, connected = emptySet(), nowEpochSeconds = now))
    }
}
