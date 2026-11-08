package com.unixcision.uniconnect.android.domain

/** Which windows of a machine are shown: all of them, the ones working or the ones waiting. */
enum class WindowFilter {
    ALL, WORKING, WAITING;

    /** Whether a window in [state] passes; a window without a known state only passes [ALL]. */
    fun accepts(state: ActivityState?): Boolean = when (this) {
        ALL -> true
        WORKING -> state == ActivityState.WORKING
        WAITING -> state == ActivityState.WAITING
    }
}
