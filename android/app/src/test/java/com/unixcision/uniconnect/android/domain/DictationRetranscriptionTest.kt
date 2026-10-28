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

    /** The MINIPC announces `transcribe.v1` but has no whisper; the Mac has. */
    private class MinipcWithoutEngine : HostTranscription {
        val asked = mutableListOf<String>()
        override suspend fun transcribe(target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript {
            asked += target.machine.id
            if (target.machine.id == "mini") throw TranscribeRefused(TranscribeRefusal.UNSUPPORTED)
            if (target.machine.id == "off") throw MachineFailure.Transport()
            return Transcript("el dictado entero")
        }
    }

    @Test
    fun aMachineWithoutAnEngineHandsTheAudioToTheNextOne() = runBlocking {
        val machines = MinipcWithoutEngine()
        val history = History()
        val fromLinux = broken.copy(machineName = "MINIPC", machineId = "mini")
        val order = DictationRetranscription.machinesFor(fromLinux, listOf(minipc, mac), preferredID = null)
        val text = DictationRetranscription(history, machines) { byteArrayOf(1) }.run(fromLinux, order, "es")
        assertEquals("el dictado entero", text)
        assertEquals(listOf("mini", "mac"), machines.asked)
        assertEquals(listOf("d1" to "el dictado entero"), history.replaced)
    }

    @Test
    fun aMachineThatDoesNotAnswerHandsTheAudioToTheNextOne() = runBlocking {
        val machines = MinipcWithoutEngine()
        val off = Machine("off", "Portátil apagado", MachineEndpoint.parse("100.64.0.3", "8855")!!)
        val text = DictationRetranscription(History(), machines) { byteArrayOf(1) }.run(broken, listOf(off, mac), "es")
        assertEquals("el dictado entero", text)
        assertEquals(listOf("off", "mac"), machines.asked)
    }

    @Test
    fun thePickedTranscriberGoesFirstThenTheDictatedOneThenTheRest() {
        val spare = Machine("spare", "Portátil viejo", MachineEndpoint.parse("100.64.0.4", "8855")!!)
        val fromLinux = broken.copy(machineName = "MINIPC", machineId = "mini")
        assertEquals(listOf(mac, minipc, spare), DictationRetranscription.machinesFor(fromLinux, listOf(spare, minipc, mac), preferredID = "mac"))
        assertEquals(listOf(minipc, spare, mac), DictationRetranscription.machinesFor(fromLinux, listOf(spare, minipc, mac), preferredID = null))
    }

    @Test
    fun itGoesToTheMachineItWasDictatedForThenByNameThenTheFirst() {
        val machines = listOf(minipc, mac)
        assertEquals(mac, DictationRetranscription.machineFor(broken, machines))
        assertEquals(mac, DictationRetranscription.machineFor(broken.copy(machineId = null), machines))
        assertEquals(minipc, DictationRetranscription.machineFor(broken.copy(machineId = null, machineName = null), machines))
    }
}
