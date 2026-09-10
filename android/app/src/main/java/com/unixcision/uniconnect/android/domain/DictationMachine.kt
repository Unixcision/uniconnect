package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * The state machine behind a dictation, fed by whatever recogniser drives it. Pure, so every
 * transition is testable without a microphone: partial text refines a listening state, a final
 * result ends it, an error ends it too unless something was already understood, and cancelling
 * throws everything away.
 *
 * The same machine drives a dictation the machine transcribes: there the recording has no partial
 * text, it carries its length in seconds, and the wait for the answer is its own state.
 */
class DictationMachine {
    private val mutable = MutableStateFlow<DictationState>(DictationState.Idle)
    val state: StateFlow<DictationState> = mutable

    /** Recording has been asked for: listening, with nothing understood yet. */
    fun onStarting() { mutable.value = DictationState.Listening() }

    /** Recording audio for a machine: no partial text will arrive, only a level and a length. */
    fun onRecording() { mutable.value = DictationState.Listening(recording = true) }

    /** The recogniser refined what it hears; ignored when not listening. */
    fun onPartial(text: String) = mutable.update { if (it is DictationState.Listening) it.copy(partial = text) else it }

    /** The voice level in dB from the recogniser; kept as 0..1 for the meter. */
    fun onLevel(rmsDb: Float) = mutable.update { if (it is DictationState.Listening) it.copy(level = normalize(rmsDb)) else it }

    /** A level already between 0 and 1, as a recorder's amplitude gives it. */
    fun onMeter(level: Float) = mutable.update { if (it is DictationState.Listening) it.copy(level = level.coerceIn(0f, 1f)) else it }

    /** How long has been recorded, for the stopwatch of a machine-side dictation. */
    fun onElapsed(seconds: Int) = mutable.update { if (it is DictationState.Listening) it.copy(seconds = seconds) else it }

    /**
     * The recording is on its way to being text; [cut] when the five-minute limit ended it, and
     * [onDevice] when Whisper reads it here. It is set from wherever the work starts, so a retry
     * after the failure was taken shows the wait too.
     */
    fun onTranscribing(cut: Boolean = false, onDevice: Boolean = false) { mutable.value = DictationState.Transcribing(cut, onDevice) }

    /** How far along a transcription on this phone is, from 0 to 100; ignored when not transcribing. */
    fun onTranscribeProgress(percent: Int) = mutable.update {
        if (it is DictationState.Transcribing) it.copy(progress = (percent.coerceIn(0, 100) / 100f)) else it
    }

    /** The final result. Empty falls back to the last partial; nothing at all is "not understood". */
    fun onFinal(text: String?) = mutable.update { current ->
        if (current !is DictationState.Listening) return@update current
        val spoken = text?.trim().orEmpty().ifEmpty { current.partial.trim() }
        if (spoken.isEmpty()) DictationState.Failed(DictationFailure.NOT_UNDERSTOOD) else DictationState.Done(spoken)
    }

    /** What the machine understood; empty text is "not understood" as well. */
    fun onTranscript(text: String) = mutable.update { current ->
        if (current !is DictationState.Transcribing) return@update current
        val spoken = text.trim()
        if (spoken.isEmpty()) DictationState.Failed(DictationFailure.NOT_UNDERSTOOD) else DictationState.Done(spoken)
    }

    /** The recogniser gave up. A "not understood" after something was heard still yields that text. */
    fun onError(failure: DictationFailure) = mutable.update { current ->
        if (current !is DictationState.Listening) return@update current
        if (failure == DictationFailure.NOT_UNDERSTOOD && current.partial.isNotBlank()) DictationState.Done(current.partial.trim())
        else DictationState.Failed(failure)
    }

    /** A failure before or outside listening, such as no engine at all or a machine that refused. */
    fun fail(failure: DictationFailure, retry: DictationRetry = DictationRetry.NONE) {
        mutable.value = DictationState.Failed(failure, retry)
    }

    /** Throws away whatever was heard. */
    fun cancel() { mutable.value = DictationState.Idle }

    /** Back to idle after the outcome was taken. */
    fun reset() { mutable.value = DictationState.Idle }

    companion object {
        /** Android reports roughly -2 dB (silence) to 10 dB (loud); mapped onto 0..1 for a meter. */
        fun normalize(rmsDb: Float): Float = ((rmsDb + 2f) / 12f).coerceIn(0f, 1f)
    }
}
