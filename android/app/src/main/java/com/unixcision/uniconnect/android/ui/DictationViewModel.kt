package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.domain.ClipHandover
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationState
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.HostDictation
import com.unixcision.uniconnect.android.domain.LocalDictation
import com.unixcision.uniconnect.android.domain.SpeechModel
import com.unixcision.uniconnect.android.domain.SpeechModelState
import com.unixcision.uniconnect.android.domain.SpeechModelStore
import com.unixcision.uniconnect.android.domain.Transcriber
import com.unixcision.uniconnect.android.domain.Transcript
import com.unixcision.uniconnect.android.domain.TranscriberRelay
import com.unixcision.uniconnect.android.domain.TranscriptionCandidate
import com.unixcision.uniconnect.android.domain.TranscriptionEngine
import com.unixcision.uniconnect.android.domain.TranscriptionMode
import com.unixcision.uniconnect.android.domain.TranscriptionNotice
import com.unixcision.uniconnect.android.domain.TranscriptionRoute
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn

/**
 * The composer's way into dictation, whichever engine runs it. Thin on purpose: the phone's
 * recogniser lives behind [Dictation], a machine's transcription behind [HostDictation], Whisper on
 * this phone behind [LocalDictation], and the choice between them behind [TranscriptionRoute], so
 * nothing about speech sits in a composable.
 *
 * The state the screen watches is the one of the engine that is running, so a bar with partial
 * text, a bar with a stopwatch and a wait with a percentage are the same bar reading the same
 * states.
 *
 * It also owns the models on the phone, because whether one is downloaded is part of the same
 * decision: the settings sheet reads [models] and the routing reads it too.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationViewModel(
    private val phone: Dictation,
    private val host: HostDictation,
    private val local: LocalDictation,
    private val speechModels: SpeechModelStore,
) : ViewModel() {
    private val engine = MutableStateFlow(TranscriptionEngine.PHONE)
    private val other = MutableStateFlow<Transcriber?>(null)
    private val notices = MutableStateFlow<TranscriptionNotice?>(null)

    val state: StateFlow<DictationState> = engine
        .flatMapLatest {
            when (it) {
                TranscriptionEngine.HOST -> host.state
                TranscriptionEngine.LOCAL -> local.state
                TranscriptionEngine.PHONE -> phone.state
            }
        }
        .stateIn(viewModelScope, SharingStarted.Eagerly, DictationState.Idle)

    /** Who is transcribing, when that is worth saying; null when it is the window's own machine. */
    val transcriber: StateFlow<Transcriber?> = other.asStateFlow()

    /** A line the composer should show once, set by anything that changes the engine mid-dictation. */
    val notice: StateFlow<TranscriptionNotice?> = notices.asStateFlow()

    /** Every Whisper model and where it is, for the settings sheet. */
    val models: StateFlow<Map<SpeechModel, SpeechModelState>> = speechModels.states

    /** Notices that are only worth saying once, and were said. */
    private val told = mutableSetOf<TranscriptionNotice>()

    /** Whether the phone's system recogniser exists; without it nothing local can be promised. */
    val phoneListens: Boolean get() = phone.available

    /** Whether the native engine loads on this phone at all, model or no model. */
    val whisperRuns: Boolean get() = local.available

    /** Whether Whisper could read a recording here right now: the engine loads and a model is downloaded. */
    val localReady: Boolean get() = local.ready

    /** Starts, or carries on, fetching [model]. */
    fun download(model: SpeechModel) = speechModels.download(model)

    /** Stops fetching [model]; what was fetched stays for the next attempt. */
    fun cancelDownload(model: SpeechModel) = speechModels.cancel(model)

    /** Removes [model] from the phone. */
    fun deleteModel(model: SpeechModel) = speechModels.delete(model)

    /** What the last dictation read here cost, or null when none has been. */
    fun lastWhisperRun(): Transcript? = local.lastRun

    /** The line was shown. */
    fun clearNotice() { notices.value = null }

    /**
     * Whether some machine would really take a recording right now: the same rule the dictation
     * would follow, refusals included, so nothing is offered that would quietly land on the phone.
     */
    fun machineWouldTranscribe(machines: List<TranscriptionCandidate>, window: DictationTarget?): Boolean =
        route(TranscriptionMode.AUTO, machines, window, null).engine == TranscriptionEngine.HOST

    /** Whether a microphone is worth offering for these machines and this setting. */
    fun canDictate(mode: TranscriptionMode, machines: List<TranscriptionCandidate>, window: DictationTarget?, chosenMachineID: String?): Boolean =
        route(mode, machines, window, chosenMachineID).canDictate(phone.available)

    /**
     * Starts a dictation for the open [window].
     *
     * Which engine runs is [TranscriptionRoute]'s decision: the window's machine, the machine the
     * reader picked, any other connected machine that can, Whisper on this phone when a model is
     * downloaded, or the system recogniser. Anything worth telling the reader is pushed to
     * [notice].
     */
    fun start(
        language: DictationLanguage,
        mode: TranscriptionMode,
        machines: List<TranscriptionCandidate>,
        window: DictationTarget?,
        chosenMachineID: String?,
    ) {
        val route = route(mode, machines, window, chosenMachineID)
        val target = route.target(window)
        when {
            route.engine == TranscriptionEngine.HOST && target != null -> {
                engine.value = TranscriptionEngine.HOST
                other.value = route.machine?.name?.let { Transcriber.OtherMachine(it) }?.takeUnless { route.ofWindow }
                host.aim(target, relayFor(machines, window))
                host.start(language)
            }
            route.engine == TranscriptionEngine.LOCAL -> {
                engine.value = TranscriptionEngine.LOCAL
                other.value = Transcriber.PhoneWhisper
                local.aim(handoverTo(machines, window))
                local.start(language)
            }
            else -> {
                engine.value = TranscriptionEngine.PHONE
                other.value = Transcriber.PhoneRecogniser
                phone.start(language)
            }
        }
        say(route.notice)
    }

    /** Stop and keep what was said. */
    fun stop() = active().stop()

    /** Stop and throw away what was said. */
    fun cancel() = active().cancel()

    /** The outcome was taken by the composer. */
    fun consume() = active().reset()

    /** Sends the recording the machine did not take again. */
    fun resend() = host.resend()

    /** The reader gave up on the recording the machine did not take; it is deleted. */
    fun discard() = host.discardKept()

    /**
     * Where a recording goes when the machine it was sent to cannot take it: the automatic rule
     * again, over the machines known when the dictation started and without the ones that are out.
     * The line naming who transcribes follows it, so the reader sees the audio move.
     */
    private fun relayFor(machines: List<TranscriptionCandidate>, window: DictationTarget?) = TranscriberRelay { out ->
        val next = TranscriptionRoute.decide(TranscriptionMode.AUTO, machines, window?.machine?.id, null, phone.available, local.ready, out)
        next.target(window)?.also { other.value = next.machine?.name?.let { name -> Transcriber.OtherMachine(name) }?.takeUnless { _ -> next.ofWindow } }
    }

    /**
     * Where a recording goes when Whisper on this phone could not read it: to a machine that can,
     * with the recording intact. Only when no machine can does the failure reach the reader.
     */
    private fun handoverTo(machines: List<TranscriptionCandidate>, window: DictationTarget?) = ClipHandover { clip ->
        val next = TranscriptionRoute.decide(TranscriptionMode.AUTO, machines, window?.machine?.id, null, phone.available, localReady = false, host.refusedMachines)
        val target = next.target(window)
        if (next.engine != TranscriptionEngine.HOST || target == null) false
        else {
            engine.value = TranscriptionEngine.HOST
            other.value = next.machine?.name?.let { Transcriber.OtherMachine(it) }?.takeUnless { next.ofWindow }
            say(TranscriptionNotice.LOCAL_FAILED_HANDED_OVER)
            host.adopt(clip, target, relayFor(machines, window))
            true
        }
    }

    private fun route(mode: TranscriptionMode, machines: List<TranscriptionCandidate>, window: DictationTarget?, chosenMachineID: String?) =
        TranscriptionRoute.decide(mode, machines, window?.machine?.id, chosenMachineID, phone.available, local.ready, host.refusedMachines)

    /** A notice that repeats is always shown; one that does not is shown the first time only. */
    private fun say(notice: TranscriptionNotice?) {
        when {
            notice == null -> Unit
            notice.repeats -> notices.value = notice
            told.add(notice) -> notices.value = notice
        }
    }

    private fun active(): Dictation = when (engine.value) {
        TranscriptionEngine.HOST -> host
        TranscriptionEngine.LOCAL -> local
        TranscriptionEngine.PHONE -> phone
    }

    override fun onCleared() {
        phone.destroy()
        host.destroy()
        local.destroy()
    }
}
