package com.unixcision.uniconnect.android.ui

/**
 * A failure that needs more than one fixed sentence: what went wrong, the host's own words when it
 * gave them, and what the phone did about it.
 *
 * Kept apart from ``MachinesViewModel.State.error`` so a host's message never stays glued to an
 * unrelated error shown later.
 */
data class ActionNotice(
    /** The phone's own sentence, as a string resource. */
    val message: Int,
    /** The host's readable message, shown as it came; null when it sent none. */
    val detail: String? = null,
    /** What happened next, as a string resource: «la ventana se ha creado sin IA…». */
    val followUp: Int? = null,
)
