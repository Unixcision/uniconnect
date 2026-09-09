package com.unixcision.uniconnect.android.domain

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Dictation the machine transcribes: the phone only records, and `mobile.audio.transcribe` gives
 * the text back. While recording there is no partial text to show, so the bar carries a level and
 * a stopwatch instead; at five minutes the recording ends on its own and is sent.
 *
 * The recording never outlives its outcome. It is deleted once transcribed, once refused for good,
 * and on a cancel; the one case where it is kept is a failure worth trying again (the machine was
 * unreachable, locked, or broke), and then only until a single [resend] has been made. A machine
 * that is merely busy is not a failure at all: there the recording waits for as many retries as
 * the reader wants, until one works or they [discardKept] it.
 *
 * Everything about the microphone is behind [VoiceRecorder] and everything about the connection
 * behind [HostTranscription], so this whole flow is exercised in tests with neither.
 *
 * ```kotlin
 * val dictation = HostDictation(recorder, transcription, scope)
 * dictation.aim(DictationTarget(machine, workspace.id, window.id))
 * dictation.start(DictationLanguage.ES_ES)
 * ```
 */
class HostDictation(
    private val recorder: VoiceRecorder,
    private val transcription: HostTranscription,
    private val scope: CoroutineScope,
    private val tickMillis: Long = 250,
    private val limitMillis: Long = 5 * 60 * 1000,
) : Dictation {
    private val machine = DictationMachine()
    private val finishing = AtomicBoolean(true)
    private var target: DictationTarget? = null
    private var language = DictationLanguage.DEVICE
    private var ticker: Job? = null
    private var sending: Job? = null

    /** The recording kept for a single retry; null when nothing is worth sending again. */
    private var kept: AudioClip? = null
    private var retried = false

    override val state: StateFlow<DictationState> get() = machine.state

    override val available: Boolean get() = recorder.available

    private val refused = mutableSetOf<String>()

    /**
     * Machines that answered `unsupported`. They are not asked again while the app runs, so the
     * route falls to another machine, or to the phone, without the reader doing anything.
     */
    val refusedMachines: Set<String> get() = refused

    /** The machine the next recording goes to, and the window it belongs to when it is that machine's. */
    fun aim(target: DictationTarget) {
        this.target = target
    }

    override fun start(language: DictationLanguage) {
        this.language = language
        sending?.cancel()
        sending = null
        dropKept()
        retried = false
        if (target == null) { machine.fail(DictationFailure.HOST_FAILED); return }
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
        ticker?.cancel()
        ticker = null
        sending?.cancel()
        sending = null
        recorder.discard()
        dropKept()
        machine.cancel()
    }

    override fun reset() = machine.reset()

    override fun destroy() {
        cancel()
    }

    /** Throws away the recording that was waiting for a retry; the reader gave up on it. */
    fun discardKept() = dropKept()

    /** Sends the kept recording once more; after this it is gone unless the machine was only busy. */
    fun resend() {
        val clip = kept ?: return
        kept = null
        retried = true
        send(clip, cut = false)
    }

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
        send(clip, cut)
    }

    private fun send(clip: AudioClip, cut: Boolean) {
        val aimed = target
        if (aimed == null) { clip.delete(); machine.fail(DictationFailure.HOST_FAILED); return }
        machine.onTranscribing(cut)
        sending = scope.launch {
            try {
                if (!AudioPayload.fits(clip.bytes)) throw TranscribeRefused(TranscribeRefusal.TOO_LARGE)
                val transcript = transcription.transcribe(aimed, clip.read(), MIME, language.code)
                clip.delete()
                machine.onTranscript(transcript.text)
            } catch (stopped: CancellationException) {
                clip.delete()
                throw stopped
            } catch (failure: Exception) {
                refuse(aimed, clip, failure)
            }
        }
    }

    /** Turns a failed send into a state, keeping the recording only when one retry makes sense. */
    private fun refuse(aimed: DictationTarget, clip: AudioClip, failure: Exception) {
        val refusal = (failure as? TranscribeRefused)?.refusal
        val reason = when (refusal) {
            TranscribeRefusal.TOO_LARGE -> DictationFailure.TOO_LONG
            TranscribeRefusal.UNSUPPORTED -> DictationFailure.HOST_UNSUPPORTED
            TranscribeRefusal.LOCKED -> DictationFailure.HOST_LOCKED
            TranscribeRefusal.BUSY -> DictationFailure.HOST_BUSY
            TranscribeRefusal.INVALID_PARAMS, TranscribeRefusal.IO_FAILED, TranscribeRefusal.UNKNOWN -> DictationFailure.HOST_FAILED
            null -> DictationFailure.HOST_UNREACHABLE
        }
        if (refusal == TranscribeRefusal.UNSUPPORTED) refused += aimed.machine.id
        // A busy machine will not be busy for long, so that recording is kept for as many tries as
        // the reader makes; the rest are failures and get exactly one.
        val passing = refusal == TranscribeRefusal.BUSY
        val worthResending = reason == DictationFailure.HOST_LOCKED || reason == DictationFailure.HOST_FAILED || reason == DictationFailure.HOST_UNREACHABLE
        if (passing || (worthResending && !retried)) {
            kept = clip
            machine.fail(reason, DictationRetry.RESEND)
        } else {
            clip.delete()
            machine.fail(reason, if (reason == DictationFailure.TOO_LONG) DictationRetry.RERECORD else DictationRetry.NONE)
        }
    }

    private fun dropKept() {
        kept?.delete()
        kept = null
    }

    private companion object {
        /** What the recorder writes and what the contract names for it. */
        const val MIME = "audio/mp4"
    }
}
