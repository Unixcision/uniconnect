package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationState
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.HostDictation
import com.unixcision.uniconnect.android.domain.TranscriptionEngine
import com.unixcision.uniconnect.android.domain.TranscriptionMode
import com.unixcision.uniconnect.android.domain.TranscriptionNotice
import com.unixcision.uniconnect.android.domain.TranscriptionRoute
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn

/**
 * The composer's way into dictation, whichever engine runs it. Thin on purpose: the phone's
 * recogniser lives behind [Dictation], the machine's transcription behind [HostDictation], and the
 * choice between them behind [TranscriptionRoute], so nothing about speech sits in a composable.
 *
 * The state the screen watches is the one of the engine that is running, so a bar with partial
 * text and a bar with a stopwatch are the same bar reading the same states.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationViewModel(private val phone: Dictation, private val host: HostDictation) : ViewModel() {
    private val engine = MutableStateFlow(TranscriptionEngine.PHONE)

    val state: StateFlow<DictationState> = engine
        .flatMapLatest { if (it == TranscriptionEngine.HOST) host.state else phone.state }
        .stateIn(viewModelScope, SharingStarted.Eagerly, DictationState.Idle)

    /** The automatic fallback is a fact about the machine: it is said once and not again. */
    private var toldHostCannot = false

    /** Whether a microphone is worth offering for [mode] against a machine that [hostTranscribes]. */
    fun canDictate(mode: TranscriptionMode, hostTranscribes: Boolean): Boolean =
        TranscriptionRoute.canDictate(mode, hostTranscribes && host.available, phone.available)

    /**
     * Starts a dictation for [target] and returns the line the composer should show, if any.
     *
     * A machine only transcribes when it announces the capability, when there is a window to
     * attach the recording to and when it has not already answered `unsupported` for this build's
     * run; otherwise the phone's own recogniser takes over.
     */
    fun start(
        language: DictationLanguage,
        mode: TranscriptionMode,
        target: DictationTarget?,
        hostTranscribes: Boolean,
    ): TranscriptionNotice? {
        val machineCan = hostTranscribes && target != null && host.available && !host.unsupported
        val route = TranscriptionRoute.decide(mode, machineCan, phone.available)
        engine.value = route.engine
        if (route.engine == TranscriptionEngine.HOST && target != null) {
            host.aim(target)
            host.start(language)
        } else {
            engine.value = TranscriptionEngine.PHONE
            phone.start(language)
        }
        val notice = route.notice ?: return null
        if (notice.repeats) return notice
        if (toldHostCannot) return null
        toldHostCannot = true
        return notice
    }

    /** Stop and keep what was said. */
    fun stop() = active().stop()

    /** Stop and throw away what was said. */
    fun cancel() = active().cancel()

    /** The outcome was taken by the composer. */
    fun consume() = active().reset()

    /** Sends the recording the machine did not take, once. */
    fun resend() = host.resend()

    private fun active(): Dictation = if (engine.value == TranscriptionEngine.HOST) host else phone

    override fun onCleared() {
        phone.destroy()
        host.destroy()
    }
}
