package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.StateFlow

/**
 * Speech to text for the composer. One recording at a time; the outcome arrives through [state]
 * as [DictationState.Done] or [DictationState.Failed] and stays there until [reset] so the
 * screen can take it exactly once.
 */
interface Dictation {
    val state: StateFlow<DictationState>

    /** Whether the phone has any speech recognition at all; without it the composer offers no microphone. */
    val available: Boolean

    /** Starts recording in [language]; the state becomes [DictationState.Listening] at once. */
    fun start(language: DictationLanguage)

    /** Stops recording and uses what was said; the state becomes Done or Failed. */
    fun stop()

    /** Stops recording and throws away what was said; the state returns to Idle. */
    fun cancel()

    /** Back to Idle after a Done or Failed was taken. */
    fun reset()

    /** Frees the recogniser; a later [start] creates it again. */
    fun destroy()
}
