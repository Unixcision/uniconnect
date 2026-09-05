package com.unixcision.uniconnect.android.domain

sealed interface MachineUpdate {
    data class Workspaces(val snapshot: MachineSnapshot) : MachineUpdate
    data class Terminal(val snapshot: TerminalSnapshot) : MachineUpdate
}
