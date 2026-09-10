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
 * A machine that cannot take the recording at all does not cost the reader what they just said:
 * the same audio goes straight to the next machine a [TranscriberRelay] names, and the only sign
 * of it is the bar saying who is transcribing now.
 *
 * The recording never outlives its outcome. It is deleted once transcribed, once there is nowhere
 * left to send it, and on a cancel; the cases where it is kept are a failure worth trying again
 * (the machine was locked or broke), and then only until a single [resend] has been made. A
 * machine that is merely busy is not a failure at all: there the recording waits for as many
 * retries as the reader wants, until one works or they [discardKept] it.
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
    private val tried = mutableSetOf<String>()
    private var relay: TranscriberRelay? = null

    /** Whether the recording in flight was the one the five-minute limit ended. */
    private var cutAtLimit = false

    /** The first machine that did not answer at all, which is still worth trying again. */
    private var unreachable: DictationTarget? = null

    /**
     * Machines that answered `unsupported`. They are not asked again while the app runs, so the
     * route falls to another machine, or to the phone, without the reader doing anything.
     */
    val refusedMachines: Set<String> get() = refused

    /**
     * The machine the next recording goes to, and the window it belongs to when it is that
     * machine's. [relay] is asked for another machine when this one turns out not to take it.
     */
    fun aim(target: DictationTarget, relay: TranscriberRelay? = null) {
        this.target = target
        this.relay = relay
    }

    override fun start(language: DictationLanguage) {
        this.language = language
        sending?.cancel()
        sending = null
        dropKept()
        retried = false
        tried.clear()
        cutAtLimit = false
        unreachable = null
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

    /**
     * Takes a recording another engine could not read and sends it to [target], with [relay] for
     * wherever else it may go.
     *
     * It is what keeps a failure of Whisper on the phone from costing the reader what they said:
     * the same file reaches a machine, and the bar only changes to name who is transcribing now.
     */
    fun adopt(clip: AudioClip, target: DictationTarget, relay: TranscriberRelay? = null) {
        finishing.set(true)
        ticker?.cancel()
        ticker = null
        sending?.cancel()
        sending = null
        dropKept()
        retried = false
        tried.clear()
        cutAtLimit = false
        unreachable = null
        this.target = target
        this.relay = relay
        send(clip, cut = false)
    }

    /** Sends the kept recording once more; after this it is gone unless the machine was only busy. */
    fun resend() {
        val clip = kept ?: return
        kept = null
        retried = true
        send(clip, cutAtLimit)
    }

    private fun finish(cut: Boolean) {
        if (!finishing.compareAndSet(false, true)) return
        val running = ticker
        ticker = null
        running?.cancel()
        cutAtLimit = cut
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

    /**
     * Turns a failed send into a state, keeping the recording whenever there is anywhere left for
     * it to go.
     *
     * A machine with no engine, and a machine that did not answer at all, are both dead ends for
     * this recording and not for the reader: the audio is passed to the next machine at once. Only
     * when there is none does it become something to read, and to say plainly that what was said
     * is gone.
     */
    private fun refuse(aimed: DictationTarget, clip: AudioClip, failure: Exception) {
        val refusal = (failure as? TranscribeRefused)?.refusal
        if (refusal == TranscribeRefusal.UNSUPPORTED) refused += aimed.machine.id
        if (refusal == null) {
            tried += aimed.machine.id
            if (unreachable == null) unreachable = aimed
        }
        if (refusal == TranscribeRefusal.UNSUPPORTED || refusal == null) {
            val elsewhere = relay?.next(refused + tried)
            if (elsewhere != null) {
                target = elsewhere
                send(clip, cutAtLimit)
                return
            }
        }
        // Out of machines, but one of them only failed to answer: that one can still take this
        // recording, so the reader is told what actually happened instead of losing what was said.
        val silent = unreachable
        if (refusal == TranscribeRefusal.UNSUPPORTED && silent != null && !retried) {
            target = silent
            kept = clip
            machine.fail(DictationFailure.HOST_UNREACHABLE, DictationRetry.RESEND)
            return
        }
        val reason = when (refusal) {
            TranscribeRefusal.TOO_LARGE -> DictationFailure.TOO_LONG
            TranscribeRefusal.UNSUPPORTED -> DictationFailure.HOST_UNSUPPORTED
            TranscribeRefusal.LOCKED -> DictationFailure.HOST_LOCKED
            TranscribeRefusal.BUSY -> DictationFailure.HOST_BUSY
            TranscribeRefusal.INVALID_PARAMS, TranscribeRefusal.IO_FAILED, TranscribeRefusal.UNKNOWN -> DictationFailure.HOST_FAILED
            null -> DictationFailure.HOST_UNREACHABLE
        }
        // A busy machine will not be busy for long, so that recording is kept for as many tries as
        // the reader makes; the rest are failures and get exactly one.
        val passing = refusal == TranscribeRefusal.BUSY
        val worthResending = reason == DictationFailure.HOST_LOCKED || reason == DictationFailure.HOST_FAILED || reason == DictationFailure.HOST_UNREACHABLE
        if (passing || (worthResending && !retried)) {
            kept = clip
            machine.fail(reason, DictationRetry.RESEND)
        } else {
            // Nowhere left to send it: the recording is gone, and the line says so rather than
            // leaving the reader wondering. A phone recogniser needs a live microphone, so what
            // was captured cannot be handed to it.
            clip.delete()
            val again = when (reason) {
                DictationFailure.TOO_LONG -> DictationRetry.RERECORD
                DictationFailure.HOST_UNSUPPORTED -> DictationRetry.DICTATE_ON_PHONE
                else -> DictationRetry.NONE
            }
            machine.fail(reason, again)
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
