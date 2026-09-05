package com.unixcision.uniconnect.android.domain

/** Failures shared by client implementations and coordinators, without exposing transport internals. */
sealed class MachineFailure : Exception() {
    class Transport : MachineFailure()
    class DeadlineExceeded : MachineFailure()
    /** [detail] is the host's human-readable message, shown next to the code so failures are diagnosable. */
    class Rejected(val code: String, val detail: String? = null) : MachineFailure()
    class ProtocolMismatch : MachineFailure()
    class UnsupportedTerminal : MachineFailure()
    class TerminalNotReady : MachineFailure()
    class InputNotQueued : MachineFailure()
}
