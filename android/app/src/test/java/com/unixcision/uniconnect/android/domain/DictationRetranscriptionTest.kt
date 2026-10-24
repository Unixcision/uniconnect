package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * A transcription that came back with only the end of a long recording can be redone from the kept
 * audio: the same bytes go to the machine again and the new text replaces the old one.
 */
class DictationRetranscriptionTest {
    private val mac = Machine("mac", "MacBook de Daniel", MachineEndpoint.parse("100.64.0.1", "8855")!!)
    private val minipc = Machine("mini", "MINIPC", MachineEndpoint.parse("100.64.0.2", "58465")!!)
    private val broken = DictationRecord(
        id = "d1", createdAt = 0, text = "Vamos a ver qué encuentras.", state = DictationRecord.State.DONE,
        audioPath = "/dictados/d1.m4a", audioBytes = 92_000, machineName = "MacBook de Daniel", machineId = "mac",
    )

    private class Machines : HostTranscription {
        var sent: Pair<DictationTarget, ByteArray>? = null
        var mime: String? = null
        override suspend fun transcribe(target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript {
            sent = target to audio
            this.mime = mime
            return Transcript("Vale amigo, revisa los baneados y los logs. Vamos a ver qué encuentras.")
        }
    }

    private class History : DictationHistory {
        val replaced = mutableListOf<Pair<String, String>>()
        override val records = MutableStateFlow(emptyList<DictationRecord>())
        override fun keep(clip: AudioClip, target: DictationTarget?) {}
        override fun transcribed(clip: AudioClip, text: String) {}
        override fun unread(clip: AudioClip) {}
        override fun replaceText(id: String, text: String) { replaced += id to text }
        override fun delete(ids: Set<String>) {}
        override fun deleteAudio(ids: Set<String>) {}
    }

    @Test
    fun theKeptAudioIsSentAgainAndTheNewTextReplacesTheOld() = runBlocking {
        val machines = Machines()
        val history = History()
        val audio = byteArrayOf(1, 2, 3)
        val text = DictationRetranscription(history, machines) { path -> audio.takeIf { path == "/dictados/d1.m4a" } }
            .run(broken, mac, "es")
        assertTrue(text.startsWith("Vale amigo"))
        assertEquals(listOf("d1" to text), history.replaced)
        assertEquals(mac, machines.sent!!.first.machine)
        assertArrayEquals(audio, machines.sent!!.second)
        assertEquals("audio/mp4", machines.mime)
    }

    @Test
    fun withoutItsAudioThereIsNothingToSend() = runBlocking {
        val retranscription = DictationRetranscription(History(), Machines()) { null }
        try {
            retranscription.run(broken.copy(audioPath = null), mac, "es")
            fail("nothing should have been sent")
        } catch (_: DictationRetranscription.MissingAudio) {}
    }

    @Test
    fun itGoesToTheMachineItWasDictatedForThenByNameThenTheFirst() {
        val machines = listOf(minipc, mac)
        assertEquals(mac, DictationRetranscription.machineFor(broken, machines))
        assertEquals(mac, DictationRetranscription.machineFor(broken.copy(machineId = null), machines))
        assertEquals(minipc, DictationRetranscription.machineFor(broken.copy(machineId = null, machineName = null), machines))
    }
}
