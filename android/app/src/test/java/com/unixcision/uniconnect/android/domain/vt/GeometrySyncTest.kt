package com.unixcision.uniconnect.android.domain.vt

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The emulator and the host PTY must end up the same size. A host resize still on its way used to
 * be cancelled by the next, identical report — tmux repeats them — and the phone was left drawing
 * another size than tmux: every line feed scrolled the whole screen and filled it with copies of
 * tmux's green status line (seen on a tablet in split screen).
 */
class GeometrySyncTest {
    private class Host {
        val gates = ArrayDeque<CompletableDeferred<Unit>>()
        val arrived = mutableListOf<Pair<Int, Int>>()
        suspend fun resize(columns: Int, rows: Int) {
            val gate = CompletableDeferred<Unit>().also { gates.addLast(it) }
            gate.await()
            arrived += columns to rows
        }
    }

    private fun sync(host: Host, canvas: IntArray) = GeometrySync(
        scope = CoroutineScope(Dispatchers.Unconfined),
        follower = GeometryFollower(),
        canvas = { canvas[0] to canvas[1] },
        resizeCanvas = { columns, rows -> canvas[0] = columns; canvas[1] = rows },
        resizeHost = host::resize,
    )

    @Test
    fun aRepeatedReportDoesNotCancelTheHostResizeOnItsWay() = runBlocking {
        val host = Host()
        val canvas = intArrayOf(80, 24)
        val sync = sync(host, canvas)
        sync.onReport(100, 30)
        assertEquals(listOf(100, 30), canvas.toList())
        sync.onReport(100, 30)  // tmux says it again while the resize is travelling
        sync.onReport(100, 30)
        host.gates.forEach { it.complete(Unit) }
        assertEquals(listOf(100 to 30), host.arrived)
    }

    @Test
    fun aNewerSizeSupersedesAnOlderOneStillInFlight() = runBlocking {
        val host = Host()
        val canvas = intArrayOf(80, 24)
        val sync = sync(host, canvas)
        sync.onReport(100, 30)
        sync.onReport(120, 40)
        host.gates.forEach { it.complete(Unit) }
        assertEquals(listOf(120 to 40), host.arrived)
        assertEquals(listOf(120, 40), canvas.toList())
    }

    @Test
    fun stoppingTheAttachmentDropsWhatIsStillTravelling() = runBlocking {
        val host = Host()
        val sync = sync(host, intArrayOf(80, 24))
        sync.onReport(100, 30)
        sync.stop()
        host.gates.forEach { it.complete(Unit) }
        assertEquals(emptyList<Pair<Int, Int>>(), host.arrived)
    }
}
