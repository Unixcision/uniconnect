package com.unixcision.uniconnect.android.domain

/** Why a dictation ended without text, in terms the screen can word. */
enum class DictationFailure { NO_PERMISSION, NO_NETWORK, NOT_UNDERSTOOD, ENGINE_UNAVAILABLE, BUSY, OTHER }

/** Where a dictation is, from the composer's point of view. */
sealed class DictationState {
    /** Nothing is being recorded. */
    data object Idle : DictationState()

    /** Recording: [partial] is what has been understood so far, [level] the voice level from 0 to 1. */
    data class Listening(val partial: String = "", val level: Float = 0f) : DictationState()

    /** Recording ended with [text] understood; the composer takes it once and resets. */
    data class Done(val text: String) : DictationState()

    /** Recording ended with nothing usable; the composer shows [reason] once and resets. */
    data class Failed(val reason: DictationFailure) : DictationState()
}
