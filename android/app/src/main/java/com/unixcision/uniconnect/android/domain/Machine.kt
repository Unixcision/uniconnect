package com.unixcision.uniconnect.android.domain

/** A user-selected endpoint, not evidence of a live or authorized connection. */
data class Machine(val id: String, val name: String, val endpoint: MachineEndpoint)
