package com.unixcision.uniconnect.android.domain

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The whole machine-side dictation without a microphone or a socket: what each answer of the
 * contract becomes on screen, and the one rule that has no exception, which is that the recording
 * is deleted on every path out.
 */
class HostDictationTest {
    private val machine = Machine("m1", "MINIPC", MachineEndpoint.parse("100.64.0.1", "58465")!!)
    private val target = DictationTarget(machine, "w1", "t1")
    private val other = Machine("m2", "Mac de Dani", MachineEndpoint.parse("100.64.0.2", "58465")!!)

    @Test
    fun whatTheMachineUnderstoodEndsInTheComposerAndTheRecordingIsGone() {
        val clip = FakeClip(120_000)
        val host = FakeTranscription { Transcript("git status", engine = "whisper.cpp") }
        val dictation = dictation(FakeRecorder(clip), host)
        dictation.aim(target)
        dictation.start(DictationLanguage.ES_ES)
        assertEquals(DictationState.Listening(recording = true), dictation.state.value)
        dictation.stop()
        awaitDone(dictation)
        assertEquals(DictationState.Done("git status"), dictation.state.value)
        assertTrue("the recording never outlives its text", clip.deleted)
        assertEquals("es", host.language)
        assertEquals("audio/mp4", host.mime)
    }

    @Test
    fun anAudioTooLongForTheMachineAsksForAShorterOneAndIsThrownAway() {
        val clip = FakeClip(200_000)
        val host = FakeTranscription { throw TranscribeRefused(TranscribeRefusal.TOO_LARGE) }
        val dictation = record(clip, host)
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.TOO_LONG, DictationRetry.RERECORD), dictation.state.value)
        assertTrue(clip.deleted)
    }

    @Test
    fun anAudioOverTheCeilingIsRefusedWithoutEvenAskingTheMachine() {
        val clip = FakeClip(AudioPayload.MAX_AUDIO_BYTES + 1)
        val host = FakeTranscription { Transcript("nunca") }
        val dictation = record(clip, host)
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.TOO_LONG, DictationRetry.RERECORD), dictation.state.value)
        assertEquals("nothing was sent", 0, host.calls.get())
        assertTrue(clip.deleted)
    }

    @Test
    fun aLockedMachineKeepsTheRecordingForOneRetryAndThenTakesIt() {
        val clip = FakeClip(90_000)
        var locked = true
        val host = FakeTranscription { if (locked) throw TranscribeRefused(TranscribeRefusal.LOCKED) else Transcript("make test") }
        val dictation = record(clip, host)
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_LOCKED, DictationRetry.RESEND), dictation.state.value)
        assertFalse("the recording waits for the retry", clip.deleted)
        dictation.reset()
        locked = false
        dictation.resend()
        awaitDone(dictation)
        assertEquals(DictationState.Done("make test"), dictation.state.value)
        assertTrue(clip.deleted)
        assertEquals(2, host.calls.get())
    }

    @Test
    fun aRecordingIsSentAgainOnlyOnceAndIsGoneAfterThat() {
        val clip = FakeClip(90_000)
        val host = FakeTranscription { throw MachineFailure.Transport() }
        val dictation = record(clip, host)
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_UNREACHABLE, DictationRetry.RESEND), dictation.state.value)
        assertFalse(clip.deleted)
        dictation.reset()
        dictation.resend()
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_UNREACHABLE, DictationRetry.NONE), dictation.state.value)
        assertTrue("after the one retry nothing is kept", clip.deleted)
        dictation.reset()
        dictation.resend()
        assertEquals("there is nothing left to send", DictationState.Idle, dictation.state.value)
        assertEquals(2, host.calls.get())
    }

    @Test
    fun aBusyMachineKeepsTheRecordingForAsManyTriesAsTheReaderMakes() {
        val clip = FakeClip(90_000)
        var busy = true
        val host = FakeTranscription { if (busy) throw TranscribeRefused(TranscribeRefusal.BUSY) else Transcript("ls -la") }
        val dictation = record(clip, host)
        // Two retries in a row still find it busy, and the recording is still there for a third.
        repeat(2) {
            awaitFailure(dictation)
            assertEquals(DictationState.Failed(DictationFailure.HOST_BUSY, DictationRetry.RESEND), dictation.state.value)
            assertFalse("waiting is not failing: the recording stays", clip.deleted)
            assertTrue("nor does it turn the machine off", dictation.refusedMachines.isEmpty())
            dictation.reset()
            dictation.resend()
        }
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_BUSY, DictationRetry.RESEND), dictation.state.value)
        assertFalse(clip.deleted)
        busy = false
        dictation.reset()
        dictation.resend()
        awaitDone(dictation)
        assertEquals(DictationState.Done("ls -la"), dictation.state.value)
        assertTrue(clip.deleted)
        assertEquals(4, host.calls.get())
    }

    @Test
    fun givingUpOnAKeptRecordingDeletesIt() {
        val clip = FakeClip(90_000)
        val dictation = record(clip, FakeTranscription { throw TranscribeRefused(TranscribeRefusal.BUSY) })
        awaitFailure(dictation)
        assertFalse(clip.deleted)
        dictation.reset()
        dictation.discardKept()
        assertTrue("the reader dismissed the line, so nothing is kept", clip.deleted)
        dictation.resend()
        assertEquals(DictationState.Idle, dictation.state.value)
    }

    @Test
    fun aMachineWithoutAnEngineHandsTheSameRecordingToTheNextOne() {
        val clip = FakeClip(90_000)
        val asked = mutableListOf<String>()
        val host = FakeTranscription { if (asked.last() == "m1") throw TranscribeRefused(TranscribeRefusal.UNSUPPORTED) else Transcript("git log") }
        host.onCall = { asked += it.machine.id }
        val dictation = dictation(FakeRecorder(clip), host)
        dictation.aim(target) { out -> DictationTarget(other).takeUnless { other.id in out } }
        dictation.start(DictationLanguage.ES_ES)
        dictation.stop()
        awaitDone(dictation)
        assertEquals("what was said is not lost: the Mac answers for the window of the other machine", DictationState.Done("git log"), dictation.state.value)
        assertEquals(listOf("m1", "m2"), asked)
        assertEquals("nothing was pressed in between", 2, host.calls.get())
        assertTrue("and it is gone once transcribed", clip.deleted)
        assertEquals("the one with no engine is marked for the next dictations", setOf("m1"), dictation.refusedMachines)
    }

    @Test
    fun withNoMachineLeftTheRecordingIsDiscardedAndSaidSo() {
        val clip = FakeClip(90_000)
        val host = FakeTranscription { throw TranscribeRefused(TranscribeRefusal.UNSUPPORTED) }
        val dictation = dictation(FakeRecorder(clip), host)
        // The relay offers the second machine, which has no engine either.
        dictation.aim(target) { out -> DictationTarget(other).takeUnless { other.id in out } }
        dictation.start(DictationLanguage.ES_ES)
        dictation.stop()
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_UNSUPPORTED, DictationRetry.RERECORD), dictation.state.value)
        assertEquals("both were tried before giving up", 2, host.calls.get())
        assertTrue("a recorded file is no use to a live recogniser, so it goes", clip.deleted)
        assertEquals(setOf("m1", "m2"), dictation.refusedMachines)
    }

    @Test
    fun aMachineThatDidNotAnswerHandsTheRecordingOnToo() {
        val clip = FakeClip(90_000)
        val asked = mutableListOf<String>()
        val host = FakeTranscription { if (asked.last() == "m1") throw MachineFailure.Transport() else Transcript("make") }
        host.onCall = { asked += it.machine.id }
        val dictation = dictation(FakeRecorder(clip), host)
        dictation.aim(target) { out -> DictationTarget(other).takeUnless { other.id in out } }
        dictation.start(DictationLanguage.ES_ES)
        dictation.stop()
        awaitDone(dictation)
        assertEquals(DictationState.Done("make"), dictation.state.value)
        assertEquals(listOf("m1", "m2"), asked)
        assertTrue("a machine that did not answer is not one without an engine", dictation.refusedMachines.isEmpty())
    }

    @Test
    fun withNowhereToRelayAMachineThatDidNotAnswerKeepsTheRecordingForARetry() {
        val clip = FakeClip(90_000)
        val dictation = record(clip, FakeTranscription { throw MachineFailure.Transport() })
        awaitFailure(dictation)
        assertEquals(DictationState.Failed(DictationFailure.HOST_UNREACHABLE, DictationRetry.RESEND), dictation.state.value)
        assertFalse(clip.deleted)
    }

    @Test
    fun onlyTheMachineThatHasNoEngineIsSkipped() {
        val clip = FakeClip(90_000)
        val dictation = dictation(FakeRecorder(clip), FakeTranscription { throw TranscribeRefused(TranscribeRefusal.UNSUPPORTED) })
        dictation.aim(DictationTarget(other), null)
        dictation.start(DictationLanguage.DEVICE)
        dictation.stop()
        awaitFailure(dictation)
        assertEquals(setOf("m2"), dictation.refusedMachines)
        assertFalse("the machine of the window was never the problem", "m1" in dictation.refusedMachines)
    }

    @Test
    fun aMachineThatBrokeIsWorthOneMoreTry() {
        listOf(TranscribeRefusal.IO_FAILED, TranscribeRefusal.INVALID_PARAMS, TranscribeRefusal.UNKNOWN).forEach { refusal ->
            val clip = FakeClip(90_000)
            val dictation = record(clip, FakeTranscription { throw TranscribeRefused(refusal) })
            awaitFailure(dictation)
            assertEquals(refusal.name, DictationState.Failed(DictationFailure.HOST_FAILED, DictationRetry.RESEND), dictation.state.value)
        }
    }

    @Test
    fun cancellingWhileRecordingThrowsTheAudioAway() {
        val clip = FakeClip(90_000)
        val recorder = FakeRecorder(clip)
        val host = FakeTranscription { Transcript("nunca") }
        val dictation = dictation(recorder, host)
        dictation.aim(target)
        dictation.start(DictationLanguage.DEVICE)
        dictation.cancel()
        assertEquals(DictationState.Idle, dictation.state.value)
        assertTrue("the half recording is discarded", recorder.discarded)
        assertEquals(0, host.calls.get())
    }

    @Test
    fun aRecorderThatCapturedNothingSaysSoInsteadOfSendingAnEmptyFile() {
        val dictation = dictation(FakeRecorder(null), FakeTranscription { Transcript("nunca") })
        dictation.aim(target)
        dictation.start(DictationLanguage.DEVICE)
        dictation.stop()
        assertEquals(DictationState.Failed(DictationFailure.NO_AUDIO), dictation.state.value)
    }

    @Test
    fun aRecorderThatCouldNotStartIsNotADictation() {
        val recorder = FakeRecorder(FakeClip(10)).also { it.startable = false }
        val dictation = dictation(recorder, FakeTranscription { Transcript("nunca") })
        dictation.aim(target)
        dictation.start(DictationLanguage.DEVICE)
        assertEquals(DictationState.Failed(DictationFailure.ENGINE_UNAVAILABLE), dictation.state.value)
    }

    @Test
    fun withoutAWindowToTranscribeForNothingIsRecorded() {
        val recorder = FakeRecorder(FakeClip(10))
        val dictation = dictation(recorder, FakeTranscription { Transcript("nunca") })
        dictation.start(DictationLanguage.DEVICE)
        assertEquals(DictationState.Failed(DictationFailure.HOST_FAILED), dictation.state.value)
        assertFalse(recorder.started)
    }

    @Test
    fun theRecordingIsCutAtTheLimitAndTheWaitSaysSo() {
        val clip = FakeClip(90_000)
        var release = false
        val host = FakeTranscription {
            while (!release) delay(1)
            Transcript("cortado")
        }
        val dictation = HostDictation(FakeRecorder(clip), host, CoroutineScope(Dispatchers.Default), tickMillis = 5, limitMillis = 25)
        dictation.aim(target)
        dictation.start(DictationLanguage.DEVICE)
        await("the recording is cut on its own") { dictation.state.value is DictationState.Transcribing }
        assertEquals(DictationState.Transcribing(cut = true), dictation.state.value)
        release = true
        awaitDone(dictation)
        assertEquals(DictationState.Done("cortado"), dictation.state.value)
        assertTrue(clip.deleted)
    }

    @Test
    fun theStopwatchAndTheMeterFollowTheRecording() {
        val recorder = FakeRecorder(FakeClip(90_000)).also { it.level = .5f }
        val dictation = HostDictation(recorder, FakeTranscription { Transcript("x") }, CoroutineScope(Dispatchers.Default), tickMillis = 5, limitMillis = 10_000)
        dictation.aim(target)
        dictation.start(DictationLanguage.DEVICE)
        await("a level reaches the bar") { (dictation.state.value as? DictationState.Listening)?.level == .5f }
        dictation.cancel()
    }

    private fun dictation(recorder: VoiceRecorder, host: HostTranscription) =
        HostDictation(recorder, host, CoroutineScope(Dispatchers.Unconfined), tickMillis = 5, limitMillis = 10_000)

    /** Records and stops at once, which is the shortest way to the answer under test. */
    private fun record(clip: FakeClip, host: FakeTranscription): HostDictation {
        val dictation = dictation(FakeRecorder(clip), host)
        dictation.aim(target)
        dictation.start(DictationLanguage.ES_ES)
        dictation.stop()
        return dictation
    }

    private fun awaitDone(dictation: HostDictation) = await("text from the machine") { dictation.state.value is DictationState.Done }

    private fun awaitFailure(dictation: HostDictation) = await("a failure") { dictation.state.value is DictationState.Failed }

    private fun await(what: String, until: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < deadline) {
            if (until()) return
            Thread.sleep(2)
        }
        throw AssertionError("timed out waiting for $what")
    }

    /** A recording that remembers whether it was deleted, which is what most of these tests assert. */
    private class FakeClip(override val bytes: Long) : AudioClip {
        var deleted = false
        override fun read(): ByteArray = ByteArray(bytes.coerceAtMost(1_024).toInt())
        override fun delete() { deleted = true }
    }

    private class FakeRecorder(private val clip: AudioClip?) : VoiceRecorder {
        var startable = true
        var started = false
        var discarded = false
        var level = 0f
        override val available = true
        override fun start(): Boolean { started = startable; return startable }
        override fun level(): Float = level
        override fun stop(): AudioClip? = clip
        override fun discard() { discarded = true }
    }

    private class FakeTranscription(private val answer: suspend () -> Transcript) : HostTranscription {
        val calls = AtomicInteger()
        var language: String? = null
        var mime: String? = null
        /** Told which machine is being asked, before the answer is decided. */
        var onCall: ((DictationTarget) -> Unit)? = null
        override suspend fun transcribe(target: DictationTarget, audio: ByteArray, mime: String, language: String?): Transcript {
            calls.incrementAndGet()
            this.language = language
            this.mime = mime
            onCall?.invoke(target)
            return answer()
        }
    }
}
