package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.DictationLanguage
import com.unixcision.uniconnect.android.domain.DictationState
import kotlinx.coroutines.flow.StateFlow

/**
 * The composer's way into dictation. Thin on purpose: the recogniser lives behind [Dictation] and
 * the state machine behind it, so nothing about speech recognition sits in a composable. The
 * recogniser is freed when the screen that owns this model goes away.
 */
class DictationViewModel(private val dictation: Dictation) : ViewModel() {
    val state: StateFlow<DictationState> get() = dictation.state

    /** Whether the phone can recognise speech at all; without it no microphone is offered. */
    val available: Boolean get() = dictation.available

    fun start(language: DictationLanguage) = dictation.start(language)

    /** Stop and keep what was said. */
    fun stop() = dictation.stop()

    /** Stop and throw away what was said. */
    fun cancel() = dictation.cancel()

    /** The outcome was taken by the composer. */
    fun consume() = dictation.reset()

    override fun onCleared() { dictation.destroy() }
}
