package com.unixcision.uniconnect.android.domain

/**
 * What the home tells at a glance: how many machines answer, how many windows they have and how
 * many AIs are working or waiting for the reader, over every machine or one of them.
 */
data class HomeSummary(
    val machines: Int,
    val connected: Int,
    val windows: Int,
    val working: Int,
    val waiting: Int,
) {
    companion object {
        /** The summary of one machine, from whether it answers and its last workspace list. */
        fun of(connected: Boolean, snapshot: MachineSnapshot?): HomeSummary {
            val windows = snapshot?.workspaces?.flatMap { it.windows }.orEmpty()
            val states = windows.map { it.activity?.state ?: ActivityState.UNKNOWN }
            return HomeSummary(
                machines = 1, connected = if (connected) 1 else 0, windows = windows.size,
                working = states.count { it == ActivityState.WORKING }, waiting = states.count { it == ActivityState.WAITING },
            )
        }

        /** Every machine added up. */
        fun total(parts: List<HomeSummary>): HomeSummary = HomeSummary(
            machines = parts.sumOf { it.machines }, connected = parts.sumOf { it.connected }, windows = parts.sumOf { it.windows },
            working = parts.sumOf { it.working }, waiting = parts.sumOf { it.waiting },
        )
    }
}
