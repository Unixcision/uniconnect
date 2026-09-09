package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationState
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.HostDictation
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
 * recogniser lives behind [Dictation], a machine's transcription behind [HostDictation], and the
 * choice between them behind [TranscriptionRoute], so nothing about speech sits in a composable.
 *
 * The state the screen watches is the one of the engine that is running, so a bar with partial
 * text and a bar with a stopwatch are the same bar reading the same states.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationViewModel(private val phone: Dictation, private val host: HostDictation) : ViewModel() {
    private val engine = MutableStateFlow(TranscriptionEngine.PHONE)
    private val other = MutableStateFlow<String?>(null)

    val state: StateFlow<DictationState> = engine
        .flatMapLatest { if (it == TranscriptionEngine.HOST) host.state else phone.state }
        .stateIn(viewModelScope, SharingStarted.Eagerly, DictationState.Idle)

    /** The name of the machine transcribing when it is not the window's own; null when it is, or when the phone listens. */
    val transcriber: StateFlow<String?> = other.asStateFlow()

    /** Notices that are only worth saying once, and were said. */
    private val told = mutableSetOf<TranscriptionNotice>()

    /** Whether a microphone is worth offering for these machines and this setting. */
    fun canDictate(mode: TranscriptionMode, machines: List<TranscriptionCandidate>, window: DictationTarget?, chosenMachineID: String?): Boolean =
        route(mode, machines, window, chosenMachineID).canDictate(phone.available)

    /**
     * Starts a dictation for the open [window] and returns the line the composer should show, if any.
     *
     * Which machine transcribes, if any, is [TranscriptionRoute]'s decision: the window's own, the
     * machine the reader picked, any other connected machine that can, or none, in which case the
     * phone's recogniser takes over.
     */
    fun start(
        language: DictationLanguage,
        mode: TranscriptionMode,
        machines: List<TranscriptionCandidate>,
        window: DictationTarget?,
        chosenMachineID: String?,
    ): TranscriptionNotice? {
        val route = route(mode, machines, window, chosenMachineID)
        val target = route.target(window)
        if (route.engine == TranscriptionEngine.HOST && target != null) {
            engine.value = TranscriptionEngine.HOST
            other.value = route.machine?.name?.takeUnless { route.ofWindow }
            host.aim(target)
            host.start(language)
        } else {
            engine.value = TranscriptionEngine.PHONE
            other.value = null
            phone.start(language)
        }
        return said(route.notice)
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

    private fun route(mode: TranscriptionMode, machines: List<TranscriptionCandidate>, window: DictationTarget?, chosenMachineID: String?) =
        TranscriptionRoute.decide(mode, machines, window?.machine?.id, chosenMachineID, phone.available, host.refusedMachines)

    /** A notice that repeats is always shown; one that does not is shown the first time only. */
    private fun said(notice: TranscriptionNotice?): TranscriptionNotice? = when {
        notice == null -> null
        notice.repeats -> notice
        !told.add(notice) -> null
        else -> notice
    }

    private fun active(): Dictation = if (engine.value == TranscriptionEngine.HOST) host else phone

    override fun onCleared() {
        phone.destroy()
        host.destroy()
    }
}
