package com.unixcision.uniconnect.android.domain

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Dictation Whisper reads on this phone, with nothing on the other end.
 *
 * It records exactly as a dictation for a machine does, because it is the same recorder and the
 * same file: sixteen kilohertz mono AAC, a level and a stopwatch on the bar, and the five-minute
 * limit. What changes is what happens next: the recording is decoded into samples here and read by
 * the model here, on a background thread, with a progress the bar shows and a cancel that stops
 * the model instead of waiting for it.
 *
 * When the engine cannot do it after all, the recording is not lost: it is offered to whoever
 * [aim] named, which in the app is the machine the automatic rule would have used. Only when
 * nobody takes it does it become a failure worth reading.
 *
 * Everything about the model file is behind [SpeechModelStore], everything about the codec behind
 * [AudioDecoder] and everything about the native library behind [LocalTranscription], so the whole
 * flow runs in a JVM test with none of the three.
 */
class LocalDictation(
    private val recorder: VoiceRecorder,
    private val decoder: AudioDecoder,
    private val engine: LocalTranscription,
    private val models: SpeechModelStore,
    private val scope: CoroutineScope,
    private val tickMillis: Long = 250,
    private val limitMillis: Long = 5 * 60 * 1000,
    private val worker: CoroutineDispatcher = Dispatchers.Default,
) : Dictation {
    private val machine = DictationMachine()
    private val finishing = AtomicBoolean(true)
    private var language = DictationLanguage.DEVICE
    private var ticker: Job? = null
    private var reading: Job? = null
    private var handover: ClipHandover? = null

    /** Read by the native engine between chunks; the only way to stop a model that is already running. */
    private val stopping = AtomicBoolean(false)

    override val state: StateFlow<DictationState> get() = machine.state

    /** A microphone and an engine that loads; without either there is nothing to offer. */
    override val available: Boolean get() = recorder.available && engine.available

    /** Whether a recording could be read here right now: the engine loads and a model is downloaded. */
    val ready: Boolean get() = engine.available && models.ready != null

    /**
     * What the last recording read here cost: how many seconds of audio, and how long the model
     * took over them. It is the only honest way to answer whether this phone is worth using for
     * a given model, so the settings sheet shows it.
     */
    var lastRun: Transcript? = null
        private set

    /** Where a recording goes when Whisper here cannot read it; null leaves nowhere for it to go. */
    fun aim(handover: ClipHandover?) {
        this.handover = handover
    }

    override fun start(language: DictationLanguage) {
        this.language = language
        reading?.cancel()
        reading = null
        stopping.set(false)
        if (models.ready == null) { machine.fail(DictationFailure.LOCAL_NO_MODEL); return }
        if (!engine.available) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        if (!recorder.start()) { machine.fail(DictationFailure.ENGINE_UNAVAILABLE); return }
        finishing.set(false)
        machine.onRecording()
        ticker = scope.launch {
            var elapsed = 0L
            while (isActive && elapsed < limitMillis) {
                delay(tickMillis)
                elapsed += tickMillis
                machine.onMeter(recorder.level())
                machine.onElapsed((elapsed / 1000).toInt())
            }
            if (elapsed >= limitMillis) finish(cut = true)
        }
    }

    override fun stop() = finish(cut = false)

    override fun cancel() {
        finishing.set(true)
        stopping.set(true)
        ticker?.cancel()
        ticker = null
        reading?.cancel()
        reading = null
        recorder.discard()
        machine.cancel()
    }

    override fun reset() = machine.reset()

    override fun destroy() = cancel()

    private fun finish(cut: Boolean) {
        if (!finishing.compareAndSet(false, true)) return
        val running = ticker
        ticker = null
        running?.cancel()
        val clip = recorder.stop()
        if (clip == null || clip.bytes <= 0) {
            clip?.delete()
            machine.fail(DictationFailure.NO_AUDIO)
            return
        }
        read(clip, cut)
    }

    private fun read(clip: AudioClip, cut: Boolean) {
        val model = models.ready
        val path = model?.let { models.path(it) }
        if (path == null) { pass(clip, DictationFailure.LOCAL_NO_MODEL); return }
        machine.onTranscribing(cut, onDevice = true)
        stopping.set(false)
        reading = scope.launch {
            try {
                val transcript = withContext(worker) {
                    val samples = decoder.decode(clip)
                    if (samples.isEmpty()) throw AudioDecodeFailed("the recording decoded to no samples")
                    val started = System.currentTimeMillis()
                    val text = engine.transcribe(samples, path, language.code, Reporter())
                    // The engine measures its own run; this is the fallback for one that does not.
                    text?.let { if (it.tookMillis > 0) it else it.copy(seconds = PcmSamples.seconds(samples), tookMillis = System.currentTimeMillis() - started) }
                }
                clip.delete()
                if (transcript == null) return@launch  // cancelled: the state is already Idle
                lastRun = transcript
                machine.onTranscript(transcript.text)
            } catch (stopped: CancellationException) {
                clip.delete()
                throw stopped
            } catch (unreadable: AudioDecodeFailed) {
                pass(clip, DictationFailure.LOCAL_UNREADABLE)
            } catch (broken: Exception) {
                pass(clip, DictationFailure.LOCAL_FAILED)
            }
        }
    }

    /**
     * Hands the recording on rather than losing it. Only when nobody takes it is it deleted and
     * [reason] shown, with the offer to say it again.
     */
    private fun pass(clip: AudioClip, reason: DictationFailure) {
        if (handover?.offer(clip) == true) {
            machine.reset()
            return
        }
        clip.delete()
        machine.fail(reason, DictationRetry.RERECORD)
    }

    /** What the native engine reports to, and asks before every chunk. */
    private inner class Reporter : TranscriptionProgress {
        override fun onProgress(percent: Int) = machine.onTranscribeProgress(percent)
        override fun cancelled(): Boolean = stopping.get()
    }
}

/**
 * Where a recording goes when the engine that was going to read it cannot.
 *
 * It exists so a failure of Whisper on the phone costs the reader nothing: the same file is handed
 * to a machine that can transcribe, exactly as a machine that refuses hands it to the next one.
 * Returning false means nobody took it and the recording is gone.
 */
fun interface ClipHandover {
    /** Takes over [clip] and reports whether it did. */
    fun offer(clip: AudioClip): Boolean
}
