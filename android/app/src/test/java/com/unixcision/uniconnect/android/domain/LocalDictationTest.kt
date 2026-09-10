package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A dictation Whisper reads on the phone, driven with no microphone, no codec and no model.
 *
 * What matters here is what happens to the recording. It is deleted the moment it has been read,
 * it is deleted when the reader cancels, and when the engine cannot read it, it is handed to
 * whoever can rather than thrown away: losing what somebody just said is the one outcome this
 * whole path exists to avoid.
 */
class LocalDictationTest {
    private val scope = CoroutineScope(Dispatchers.Unconfined)
    private val recorder = FakeRecorder()
    private val decoder = FakeDecoder()
    private val engine = FakeEngine()
    private val models = FakeModels()

    private fun dictation() = LocalDictation(recorder, decoder, engine, models, scope, worker = Dispatchers.Unconfined)

    @Test
    fun aRecordingIsReadHereAndBecomesTheText() {
        engine.text = "arranca el servidor de pruebas"
        val local = dictation()
        local.start(DictationLanguage.ES_ES)
        assertEquals(DictationState.Listening(recording = true), local.state.value)
        local.stop()
        assertEquals(DictationState.Done("arranca el servidor de pruebas"), local.state.value)
        assertTrue("nothing is kept once it has been read", recorder.clip.deleted)
        assertEquals("es", engine.language)
        assertEquals("/models/base.bin", engine.modelPath)
    }

    @Test
    fun theWaitSaysItIsHappeningHereAndHowFarAlongItIs() {
        val local = dictation()
        engine.onRun = { progress ->
            progress?.onProgress(40)
            assertEquals(DictationState.Transcribing(cut = false, onDevice = true, progress = 0.4f), local.state.value)
        }
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertTrue(local.state.value is DictationState.Done)
    }

    @Test
    fun withoutAModelNothingIsEvenRecorded() {
        models.downloaded = null
        val local = dictation()
        local.start(DictationLanguage.DEVICE)
        assertEquals(DictationState.Failed(DictationFailure.LOCAL_NO_MODEL), local.state.value)
        assertFalse("the microphone never opened", recorder.started)
    }

    @Test
    fun anEngineThatBreaksHandsTheRecordingToWhoeverWillTakeIt() {
        engine.failure = LocalTranscriptionFailed("out of memory")
        var handed: AudioClip? = null
        val local = dictation()
        local.aim { clip -> handed = clip; true }
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertSame("the same file, not a re-recording", recorder.clip, handed)
        assertFalse("whoever took it owns it now", recorder.clip.deleted)
        assertEquals("the bar follows the engine that took over", DictationState.Idle, local.state.value)
    }

    @Test
    fun aRecordingNobodyWillTakeIsAFailureWorthSayingAgain() {
        engine.failure = LocalTranscriptionFailed("out of memory")
        val local = dictation()
        local.aim { false }
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertEquals(DictationState.Failed(DictationFailure.LOCAL_FAILED, DictationRetry.RERECORD), local.state.value)
        assertTrue("there is nowhere for it to go, and the reader is told so", recorder.clip.deleted)
    }

    @Test
    fun aRecordingThePhoneCannotDecodeIsAlsoWorthHandingOver() {
        decoder.failure = AudioDecodeFailed("no audio track")
        var handed = false
        val local = dictation()
        local.aim { handed = true; true }
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertTrue("a machine reads the same file with its own codec", handed)
    }

    @Test
    fun aRecordingThatDecodesToNothingIsNotSentToTheModel() {
        decoder.samples = FloatArray(0)
        val local = dictation()
        local.aim { false }
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertEquals(DictationState.Failed(DictationFailure.LOCAL_UNREADABLE, DictationRetry.RERECORD), local.state.value)
        assertFalse("the model was never asked to read silence", engine.ran)
    }

    @Test
    fun cancellingThrowsTheRecordingAwayAndTellsTheModelToStop() {
        val local = dictation()
        local.start(DictationLanguage.DEVICE)
        local.cancel()
        assertEquals(DictationState.Idle, local.state.value)
        assertTrue(recorder.discarded)
        assertFalse("nothing was ever handed to the engine", engine.ran)
    }

    @Test
    fun aRunTheReaderStoppedComesBackAsNothingRatherThanHalfASentence() {
        engine.cancelled = true
        val local = dictation()
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertEquals("the cancel already put the bar back", DictationState.Transcribing(cut = false, onDevice = true), local.state.value)
        assertTrue(recorder.clip.deleted)
    }

    @Test
    fun anEmptyRecordingIsSaidPlainlyAndNotSentAnywhere() {
        recorder.empty = true
        val local = dictation()
        local.start(DictationLanguage.DEVICE)
        local.stop()
        assertEquals(DictationState.Failed(DictationFailure.NO_AUDIO), local.state.value)
        assertFalse(engine.ran)
    }

    @Test
    fun whisperIsOnlyOfferedWhenBothTheEngineAndAModelAreThere() {
        val local = dictation()
        assertTrue(local.ready)
        models.downloaded = null
        assertFalse("an engine with no model transcribes nothing", local.ready)
        models.downloaded = SpeechModel.BASE
        engine.available = false
        assertFalse("a model with no engine transcribes nothing either", local.ready)
    }

    @Test
    fun theMeasurementCoversTheWholeWaitAndNotJustTheModel() {
        // An engine that reports a suspiciously small run of its own: what is kept is the wait
        // around everything, because opening the model and decoding are also waited for.
        engine.reported = Transcript("hola", "whisper.cpp", seconds = 99.0, tookMillis = 1)
        decoder.samples = FloatArray(PcmSamples.RATE * 3) { 0.1f }
        val local = dictation()
        local.start(DictationLanguage.DEVICE)
        local.stop()
        val run = local.lastRun!!
        assertEquals("the length comes from the samples, not from the engine", 3.0, run.seconds, 1e-9)
        assertTrue("the engine's own figure is not the whole wait", run.tookMillis >= 0)
        assertEquals("hola", run.text)
    }

    private class FakeClip(override val bytes: Long = 1_024) : AudioClip {
        var deleted = false
        override fun read(): ByteArray = ByteArray(bytes.toInt())
        override fun delete() { deleted = true }
    }

    private class FakeRecorder : VoiceRecorder {
        val clip = FakeClip()
        var started = false
        var discarded = false
        var empty = false
        override val available = true
        override fun start(): Boolean { started = true; return true }
        override fun level(): Float = 0.5f
        override fun stop(): AudioClip? = if (empty) null else clip
        override fun discard() { discarded = true }
    }

    private class FakeDecoder : AudioDecoder {
        var samples = FloatArray(16_000) { 0.1f }
        var failure: Exception? = null
        override fun decode(clip: AudioClip): FloatArray {
            failure?.let { throw it }
            return samples
        }
    }

    private class FakeEngine : LocalTranscription {
        override var available = true
        var text = "hola"
        var language: String? = null
        var modelPath = ""
        var ran = false
        var cancelled = false
        var failure: Exception? = null
        var onRun: (TranscriptionProgress?) -> Unit = {}
        var reported: Transcript? = null

        override suspend fun transcribe(samples: FloatArray, modelPath: String, language: String?, progress: TranscriptionProgress?): Transcript? {
            ran = true
            this.language = language
            this.modelPath = modelPath
            onRun(progress)
            failure?.let { throw it }
            return if (cancelled) null else reported ?: Transcript(text)
        }
    }

    private class FakeModels : SpeechModelStore {
        var downloaded: SpeechModel? = SpeechModel.BASE
        override val states: StateFlow<Map<SpeechModel, SpeechModelState>> = MutableStateFlow(emptyMap())
        override val ready: SpeechModel? get() = downloaded
        override fun path(model: SpeechModel): String? = "/models/base.bin"
        override fun download(model: SpeechModel) = Unit
        override fun cancel(model: SpeechModel) = Unit
        override fun delete(model: SpeechModel) = Unit
    }
}
