package com.unixcision.uniconnect.android.domain

/**
 * A machine the phone could ask to transcribe: whether it announces `transcribe.v1` and whether
 * it is answering right now. Both matter, because a machine that cannot be reached cannot
 * transcribe however good its engine is.
 */
data class TranscriptionCandidate(val machine: Machine, val transcribes: Boolean, val connected: Boolean) {
    /** Whether this machine can take a recording right now. */
    val ready: Boolean get() = transcribes && connected
}
