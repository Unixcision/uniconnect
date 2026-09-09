package com.unixcision.uniconnect.android.domain

/**
 * What an AI inside a window is doing, as the host reports it (contract `activity.v1`).
 *
 * The host merges its sources (agent hooks, the pane title, the visible screen, output activity);
 * the phone only shows the result. ``WAITING`` outranks ``WORKING`` when a workspace sums up its
 * windows: a question for the reader matters more than work in progress.
 */
enum class ActivityState(val rank: Int) {
    UNKNOWN(0), IDLE(1), WORKING(2), WAITING(3);

    companion object {
        fun parse(raw: String?): ActivityState = when (raw) {
            "working" -> WORKING
            "waiting" -> WAITING
            "idle" -> IDLE
            else -> UNKNOWN
        }

        /** The state a workspace shows for its windows: the most pressing one. */
        fun summarize(states: Iterable<ActivityState>): ActivityState = states.maxByOrNull { it.rank } ?: UNKNOWN
    }
}
