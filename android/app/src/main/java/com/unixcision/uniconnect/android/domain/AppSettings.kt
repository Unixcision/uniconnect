package com.unixcision.uniconnect.android.domain

/**
 * The preferences that change how the app behaves, with the defaults it ships with.
 *
 * - Parameter terminalView: how a terminal is laid out when a window is opened.
 * - Parameter showExtraKeys: whether the control key row starts open.
 * - Parameter probeOnOpen: whether the list asks every machine if it answers, without being asked.
 * - Parameter designTheme: which of the four designs dresses the app.
 * - Parameter colorMode: whether that design is shown light, dark or as the phone is set.
 */
data class AppSettings(
    val terminalView: TerminalView = TerminalView.PAN,
    val showExtraKeys: Boolean = false,
    val probeOnOpen: Boolean = true,
    val designTheme: DesignTheme = DesignTheme.SERENO,
    val colorMode: ColorMode = ColorMode.SYSTEM,
)
