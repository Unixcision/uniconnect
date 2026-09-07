package com.unixcision.uniconnect.android.domain

/**
 * The preferences that change how the app behaves, with the defaults it ships with.
 *
 * - Parameter terminalView: how a terminal is laid out when a window is opened.
 * - Parameter showExtraKeys: whether the control key row starts open.
 * - Parameter probeOnOpen: whether the list asks every machine if it answers, without being asked.
 */
data class AppSettings(
    val terminalView: TerminalView = TerminalView.PAN,
    val showExtraKeys: Boolean = false,
    val probeOnOpen: Boolean = true,
)
