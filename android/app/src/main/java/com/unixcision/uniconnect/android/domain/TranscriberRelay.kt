package com.unixcision.uniconnect.android.domain

/**
 * Where a recording goes when the machine it was sent to cannot take it.
 *
 * A machine that answers `unsupported`, or one that is simply not there, must not cost the reader
 * what they just said: the same audio is offered to the next machine that can transcribe, with
 * nothing to press. The rule that picks it is [TranscriptionRoute]'s, asked again at that moment.
 */
fun interface TranscriberRelay {
    /** The next machine to try, knowing which ones are already out; null when none is left. */
    fun next(out: Set<String>): DictationTarget?
}
