package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.DictationSearch
import com.unixcision.uniconnect.android.domain.SentMessage
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every text sent from the composer is kept before it leaves, so a send that does not arrive or a
 * window that hangs never costs what was written; it survives a restart, and one the app died
 * sending comes back as unconfirmed rather than as sent or lost.
 */
class FileSentMessageHistoryTest {
    private val directory: File = Files.createTempDirectory("enviados").toFile()
    private var now = 1_000L

    @After
    fun cleanUp() { directory.deleteRecursively() }

    private fun history(max: Int = 2_000) = FileSentMessageHistory(directory, clock = { now }, maxMessages = max)

    @Test
    fun aTextIsKeptBeforeItLeavesAndSettledWithTheAnswer() {
        val history = history()
        val id = history.record("revisa los logs de PRE", withEnter = true, machineName = "MacBook de Daniel", windowName = "APP 2")
        val sending = history.messages.value.single()
        assertEquals(SentMessage.State.SENDING, sending.state)
        assertEquals("APP 2", sending.windowName)
        assertTrue(sending.withEnter)

        history.settle(id, delivered = true)
        assertEquals(SentMessage.State.DELIVERED, history.messages.value.single().state)
        val failed = history.record("otro", withEnter = false, machineName = null, windowName = null)
        history.settle(failed, delivered = false)
        assertEquals(SentMessage.State.FAILED, history.messages.value.first().state)
    }

    @Test
    fun everythingSurvivesARestartAndAMessageCutMidSendComesBackUnconfirmed() {
        val first = history()
        val delivered = first.record("llegó", withEnter = true, machineName = "MINIPC", windowName = "minipc")
        first.settle(delivered, delivered = true)
        now = 2_000
        first.record("se quedó a medias", withEnter = true, machineName = "MINIPC", windowName = "minipc")

        val reopened = history().messages.value
        assertEquals(listOf("se quedó a medias", "llegó"), reopened.map { it.text })
        assertEquals(listOf(SentMessage.State.UNCONFIRMED, SentMessage.State.DELIVERED), reopened.map { it.state })
        assertEquals("minipc", reopened.last().windowName)
    }

    @Test
    fun theOldestGoFirstOverTheLimitAndDeletingIsForGood() {
        val history = history(max = 2)
        history.record("uno", withEnter = true, machineName = null, windowName = null)
        now = 2_000
        val two = history.record("dos", withEnter = true, machineName = null, windowName = null)
        now = 3_000
        history.record("tres", withEnter = true, machineName = null, windowName = null)
        assertEquals(listOf("tres", "dos"), history.messages.value.map { it.text })

        history.delete(setOf(two))
        assertEquals(listOf("tres"), history().messages.value.map { it.text })
        history.clear()
        assertTrue(history().messages.value.isEmpty())
    }

    @Test
    fun aHistoryOverALowerLimitIsTrimmedAsSoonAsItIsOpened() {
        val generous = history(max = 10)
        listOf("uno", "dos", "tres").forEach { text -> now += 1; generous.record(text, withEnter = true, machineName = null, windowName = null) }
        assertEquals(listOf("tres", "dos"), history(max = 2).messages.value.map { it.text })
        assertEquals(listOf("tres", "dos"), history(max = 10).messages.value.map { it.text })
    }

    @Test
    fun theSearchFindsTheWindowTheMachineAndTheTextWithoutAccents() {
        val message = SentMessage("m", 0, "¿Ya le has dado al VPS los archivos?", true, SentMessage.State.DELIVERED, "MacBook de Daniel", "APP 2")
        assertTrue(DictationSearch.matches(message, "app 2"))
        assertTrue(DictationSearch.matches(message, "macbook archivos"))
        assertTrue(DictationSearch.matches(message, "vps"))
        assertFalse(DictationSearch.matches(message, "minipc"))
    }
}
