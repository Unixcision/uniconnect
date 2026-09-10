package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.StateFlow

/**
 * The models the phone holds and everything that changes that.
 *
 * Nothing here happens on its own: a model is fetched when the reader asks for it, and removed
 * when they ask for that. The state of every model is published together so the settings sheet
 * reads one value.
 */
interface SpeechModelStore {
    /** Every model and where it is right now. */
    val states: StateFlow<Map<SpeechModel, SpeechModelState>>

    /** The best model that is ready, or null when none is. */
    val ready: SpeechModel?

    /** The file to hand the engine for [model], or null when it is not ready. */
    fun path(model: SpeechModel): String?

    /** Starts, or resumes, fetching [model]. Asking twice while it runs does nothing. */
    fun download(model: SpeechModel)

    /** Stops the download; what was fetched stays on disk for the next attempt. */
    fun cancel(model: SpeechModel)

    /** Removes [model] and anything half-fetched of it. */
    fun delete(model: SpeechModel)
}
