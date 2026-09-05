package com.unixcision.uniconnect.android.domain

/** Stable host-owned IDs; opening or reconnecting this target never creates a terminal. */
data class TerminalTarget(val workspaceID: String, val windowID: String)
