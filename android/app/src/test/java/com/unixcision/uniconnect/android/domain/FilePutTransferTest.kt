package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.security.MessageDigest

/** Chunking, indices, checksum, progress and abort, against a session that only records. */
class FilePutTransferTest {
    private val data = ByteArray(2_621_440) { (it * 7 % 251).toByte() } // 2.5 MiB

    private fun sha256(bytes: ByteArray) = FilePutTransfer.hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    @Test
    fun aFileIsCutIntoTheHostsChunkSizeWithConsecutiveIndices() = runBlocking {
        val session = RecordingSession(chunkBytes = 1024 * 1024)
        val seen = mutableListOf<Long>()
        val outcome = FilePutTransfer.run(session, "ws", "win", "foto.jpg", data.size.toLong(), "image/jpeg", { ByteArrayInputStream(data) }) { seen.add(it) }
        assertEquals(listOf(0, 1, 2), session.chunks.map { it.first })
        assertEquals(listOf(1024 * 1024, 1024 * 1024, 524_288), session.chunks.map { it.second.size })
        assertArrayEquals(data, session.received())
        assertEquals(sha256(data), session.committed)
        assertEquals(data.size.toLong(), seen.last())
        assertEquals(seen.sorted(), seen)
        assertEquals("~/UniConnect/Entrada/20260909/foto.jpg", outcome.path)
        assertNull(session.aborted)
        assertEquals(listOf("ws", "win", "foto.jpg", data.size.toLong(), "image/jpeg"), session.begun)
    }

    @Test
    fun aHostAskingForMoreThanAMebibyteIsCutDownToTheContract() = runBlocking {
        val session = RecordingSession(chunkBytes = 4 * 1024 * 1024)
        FilePutTransfer.run(session, "ws", null, "x.bin", data.size.toLong(), null, { ByteArrayInputStream(data) }) {}
        assertTrue(session.chunks.all { it.second.size <= FilePutTransfer.MAX_CHUNK_BYTES })
        assertEquals(3, session.chunks.size)
    }

    @Test
    fun anEmptyFileCommitsWithoutChunks() = runBlocking {
        val session = RecordingSession(chunkBytes = 64)
        FilePutTransfer.run(session, "ws", null, "vacio.txt", 0, null, { ByteArrayInputStream(ByteArray(0)) }) {}
        assertTrue(session.chunks.isEmpty())
        assertEquals(sha256(ByteArray(0)), session.committed)
    }

    @Test
    fun aFileOverTheContractIsRefusedBeforeBegin() = runBlocking {
        val session = RecordingSession(chunkBytes = 64)
        try {
            FilePutTransfer.run(session, "ws", null, "enorme.iso", FilePutTransfer.MAX_SIZE_BYTES + 1, null, { ByteArrayInputStream(ByteArray(0)) }) {}
            fail("expected too_large")
        } catch (e: MachineFailure.Rejected) {
            assertEquals("too_large", e.code)
        }
        assertNull(session.begun)
    }

    @Test
    fun aChunkTheHostRefusesAbortsTheTransferAndSurfacesTheCode() = runBlocking {
        val session = RecordingSession(chunkBytes = 1024 * 1024, failAtIndex = 1, failCode = "locked")
        try {
            FilePutTransfer.run(session, "ws", null, "x.bin", data.size.toLong(), null, { ByteArrayInputStream(data) }) {}
            fail("expected a rejection")
        } catch (e: MachineFailure.Rejected) {
            assertEquals("locked", e.code)
        }
        assertEquals("t-1", session.aborted)
        assertNull(session.committed)
    }

    @Test
    fun aFileThatEndsEarlyIsUnreadableAndAborted() = runBlocking {
        val session = RecordingSession(chunkBytes = 1024)
        try {
            FilePutTransfer.run(session, "ws", null, "corto.bin", 5_000, null, { ByteArrayInputStream(ByteArray(3_000)) }) {}
            fail("expected unreadable")
        } catch (e: UploadFailure.Unreadable) {
            assertEquals("corto.bin", e.name)
        }
        assertEquals("t-1", session.aborted)
        assertFalse(session.chunks.isEmpty())
    }

    @Test
    fun theRemotePathIsPastedOnlyWhenTheFileGotThere() {
        assertEquals("/srv/uniconnect-entrada/a.png", FilePutOutcome("/home/d/UniConnect/Entrada/a.png", FilePutLocation.REMOTE, "/srv/uniconnect-entrada/a.png").pastePath)
        assertEquals("/home/d/UniConnect/Entrada/a.png", FilePutOutcome("/home/d/UniConnect/Entrada/a.png", FilePutLocation.HOST, null, "scp: connection refused").pastePath)
        assertEquals("/home/d/UniConnect/Entrada/a.png", FilePutOutcome("/home/d/UniConnect/Entrada/a.png", FilePutLocation.REMOTE, null).pastePath)
    }

    private class RecordingSession(private val chunkBytes: Int, private val failAtIndex: Int = -1, private val failCode: String = "invalid_params") : FilePutSession {
        var begun: List<Any?>? = null
        val chunks = mutableListOf<Pair<Int, ByteArray>>()
        var committed: String? = null
        var aborted: String? = null

        override suspend fun begin(workspaceID: String, terminalID: String?, name: String, size: Long, mime: String?): FilePutTicket {
            begun = listOf(workspaceID, terminalID, name, size, mime)
            return FilePutTicket("t-1", chunkBytes)
        }

        override suspend fun chunk(transferID: String, index: Int, data: ByteArray): Long {
            assertEquals("t-1", transferID)
            if (index == failAtIndex) throw MachineFailure.Rejected(failCode)
            assertEquals(chunks.size, index)
            chunks.add(index to data)
            return received().size.toLong()
        }

        override suspend fun commit(transferID: String, sha256: String): FilePutOutcome {
            committed = sha256
            return FilePutOutcome("~/UniConnect/Entrada/20260909/${begun?.get(2)}", FilePutLocation.HOST)
        }

        override suspend fun abort(transferID: String) { aborted = transferID }

        fun received(): ByteArray = chunks.fold(ByteArray(0)) { acc, (_, bytes) -> acc + bytes }
    }
}
