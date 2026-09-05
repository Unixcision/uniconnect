package com.unixcision.uniconnect.android.domain

/** The acknowledged host-owned IDs and authoritative tree returned by an explicit mutation. */
data class CreationResult(val snapshot: MachineSnapshot, val workspaceID: String, val windowID: String?)
