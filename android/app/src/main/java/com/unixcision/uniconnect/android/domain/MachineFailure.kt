package com.unixcision.uniconnect.android.domain

/** Failures shared by client implementations and coordinators, without exposing transport internals. */
sealed class MachineFailure : Exception() {
    class Transport : MachineFailure()
    class DeadlineExceeded : MachineFailure()
    /**
     * [detail] is the host's human-readable message, shown next to the code so failures are diagnosable.
     *
     * [failureCause] and [createdTerminalID] come with errors that need more than a code: `run_as_failed`
     * says why the user switch failed and which window was created anyway (`run-as.v1`).
     */
    class Rejected(
        val code: String,
        val detail: String? = null,
        // Not `cause`: that name belongs to Throwable.
        val failureCause: String? = null,
        val createdTerminalID: String? = null,
    ) : MachineFailure()
    class ProtocolMismatch : MachineFailure()
    class UnsupportedTerminal : MachineFailure()
    class TerminalNotReady : MachineFailure()
    class InputNotQueued : MachineFailure()
}
