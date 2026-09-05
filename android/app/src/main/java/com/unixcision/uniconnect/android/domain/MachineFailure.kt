package com.unixcision.uniconnect.android.domain

/** Failures shared by client implementations and coordinators, without exposing transport internals. */
sealed class MachineFailure : Exception() {
    class Transport : MachineFailure()
    class DeadlineExceeded : MachineFailure()
    class Rejected(val code: String) : MachineFailure()
    class ProtocolMismatch : MachineFailure()
    class UnsupportedTerminal : MachineFailure()
    class InputNotQueued : MachineFailure()
}
