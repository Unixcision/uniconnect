package com.unixcision.uniconnect.android.domain

/**
 * A machine the phone could ask to transcribe: whether it announces `transcribe.v1` and whether
 * it is answering right now. Both matter, because a machine that cannot be reached cannot
 * transcribe however good its engine is.
 */
data class TranscriptionCandidate(val machine: Machine, val transcribes: Boolean, val connected: Boolean) {
    /** Whether this machine can take a recording right now. */
    val ready: Boolean get() = transcribes && connected

    companion object {
        /**
         * The candidate for a saved machine, from what the phone last learned about it.
         *
         * - Parameter snapshot: the last workspace list it answered, or null if it never did.
         * - Parameter watched: whether the phone keeps a live link to it right now.
         * - Parameter lastContactFailed: whether the last attempt to reach it failed.
         */
        fun of(machine: Machine, snapshot: MachineSnapshot?, watched: Boolean, lastContactFailed: Boolean): TranscriptionCandidate =
            TranscriptionCandidate(machine, transcribes = snapshot?.transcribes == true, connected = watched)
    }
}
