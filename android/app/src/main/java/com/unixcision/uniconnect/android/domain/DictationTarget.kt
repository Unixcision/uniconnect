package com.unixcision.uniconnect.android.domain

/**
 * The machine a recording is sent to, and the window it belongs to when that machine is the
 * window's own.
 *
 * The contract takes `workspace_id` and `terminal_id` as optional, and they mean nothing to a
 * machine that does not own the window: when a laptop transcribes for a terminal on another
 * server, they are left out and only the text comes back.
 */
data class DictationTarget(val machine: Machine, val workspaceID: String? = null, val terminalID: String? = null)
